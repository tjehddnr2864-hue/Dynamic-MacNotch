import AppKit
import SwiftUI

/// 화면 녹화 표시 (⌘⇧5, QuickTime 등 시스템 녹화).
/// 1.5초마다 '화면을 캡처하는 쪽이 있는지'(SkyLight, 매우 가벼운 호출)만 보고,
/// 있을 때만 녹화 도구(screencaptureui·QuickTime) 프로세스가 떠 있는지 확인해 녹화로 판단한다.
/// (screencaptureui는 '앱'으로 실행되지 않아 앱 실행 알림으로는 알 수 없다)
final class RecordingMonitor: ObservableObject {
    @Published private(set) var startedAt: Date?
    /// 방금 끝난 녹화 (저장된 파일을 찾으면 url이 채워짐). 잠시 뒤 비운다.
    @Published private(set) var finished: Finished?

    struct Finished: Equatable {
        var date: Date
        var url: URL?
        var folder: URL
    }

    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private var timer: Timer?
    /// 이 앱이 정지시켰는지 (끝났을 때 '저장됨'으로 알림)
    private var stopRequested = false

    private typealias WatcherFn = @convention(c) () -> Bool
    private static let screenWatcherPresent: WatcherFn? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let sym = dlsym(h, "SLSIsScreenWatcherPresent") else { return nil }
        return unsafeBitCast(sym, to: WatcherFn.self)
    }()

    init(center: ActivityCenter) {
        self.center = center
    }

    func start() { schedule(interval: 1.5) }

    /// 평소 1.5초, 스크린샷 도구가 떠 있는 동안은 0.4초마다 확인 (녹화 시작·끝을 1초 안에 반영)
    private var interval: TimeInterval = 0
    private func schedule(interval: TimeInterval) {
        guard interval != self.interval else { return }
        self.interval = interval
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = interval * 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 스크린샷을 찍은 뒤, 스크린샷 도구의 전체 화면 창이 남아 있는 동안은 녹화로 보지 않는다.
    /// (⌘⇧5로 스크린샷을 찍으면 도구 막대가 사라진 채 전체 화면 창이 한동안 남아 녹화와 같은 모양이 된다)
    /// 창이 사라지거나 도구 막대가 다시 나타나면 풀린다.
    private var suppressedAfterScreenshot = false

    /// 스크린샷이 들어왔다: 방금 녹화로 잘못 본 것이 있으면 완료 알림 없이 거둔다.
    /// 이미 한참 녹화 중이면(20초 이상) 녹화 도중 찍은 스크린샷이므로 건드리지 않는다.
    func screenshotTaken() {
        if let since = startedAt {
            guard Date().timeIntervalSince(since) < 20 else { return }
            startedAt = nil
            center.removePersistent(.recording)
            center.dismissTransient(kind: .recording)
        }
        suppressedAfterScreenshot = true
        positiveStreak = 0
    }

    /// 연속으로 녹화로 보인 횟수 (두 번 연속이어야 시작으로 본다 — 잠깐의 오감지 방지)
    private var positiveStreak = 0

    private func poll() {
        let procs = Self.recorderProcesses()
        schedule(interval: procs.ui || procs.cliVideo || startedAt != nil ? 0.4 : 1.5)
        if suppressedAfterScreenshot {
            let ui = procs.ui ? Self.captureUI() : nil
            if ui == nil || ui?.fullScreenLayer == false || ui?.toolbar == true { suppressedAfterScreenshot = false }
        }
        let recording = settings.recordingEnabled && !suppressedAfterScreenshot
            && Self.systemIsRecording(alreadyRecording: startedAt != nil, procs: procs)
        positiveStreak = recording ? positiveStreak + 1 : 0
        if recording, startedAt == nil, positiveStreak >= 2 {
            started()
        } else if !recording, startedAt != nil {
            stopped()
        }
    }

    private func started() {
        let now = Date()
        startedAt = now
        stopRequested = false
        if settings.recordingStyle == .persistent {
            // 계속 표시: 왼쪽 깜빡이는 빨간 점(누르면 정지), 오른쪽 녹화 시간
            center.setPersistent(NotchActivity(
                kind: .recording, priority: ActivityPriority.recording, symbol: "record.circle.fill", tint: .red,
                value: .elapsed(now), title: T("화면 녹화", "Screen Recording"), wing: NotchActivity.compactWing))
        } else {
            // 잠깐 알림 후 들어감
            center.post(NotchActivity(
                kind: .recording, priority: ActivityPriority.recording, duration: 3, symbol: "record.circle.fill", tint: .red,
                value: .text(T("녹화 시작", "Recording")), title: T("화면 녹화", "Screen Recording"),
                wing: NetworkMonitor.wing(for: T("녹화 시작", "Recording"))))
        }
    }

    private func stopped() {
        let began = startedAt ?? Date()
        startedAt = nil
        finished = Finished(date: Date(), url: nil,
                            folder: AppSettings.folderURL(settings.recordingFolder, fallback: AppSettings.defaultRecordingFolder))
        locateSavedFile(since: began)
        center.removePersistent(.recording)
        center.dismissTransient(kind: .recording)
        stopRequested = false
        // 녹화 완료: 다운로드 완료와 같은 체크 아이콘. 메뉴바 정지 버튼을 누르느라 커서가 노치 위에 있어도 곧 사라진다
        center.post(NotchActivity(kind: .recording, duration: 1.8, symbol: "video.fill", tint: .green, value: .check,
                                  title: T("녹화 완료", "Recording Saved"), wing: 46, ignoresHoverPause: true))
    }

    // MARK: - 저장된 파일 찾기

    private var locateWork: DispatchWorkItem?
    private var clearWork: DispatchWorkItem?

    /// macOS 화면 기록 저장 위치 (스크린샷 설정의 저장 위치, 기본은 데스크탑)
    static func saveFolder() -> URL {
        if let path = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// 녹화가 끝난 뒤 저장 위치에 새로 생긴 동영상을 찾는다.
    /// macOS는 화면 오른쪽 아래 썸네일이 사라진 뒤 저장하므로 최대 15초 동안 0.5초마다 확인한다.
    private func locateSavedFile(since began: Date) {
        locateWork?.cancel()
        clearWork?.cancel()
        var tries = 0
        func attempt() {
            tries += 1
            guard let current = finished else { return }
            // 지정한 폴더에서 먼저 찾고, 없으면 macOS 스크린샷 저장 위치에서 찾는다
            let found = Self.newestRecording(in: current.folder, since: began.addingTimeInterval(-2))
                ?? Self.newestRecording(in: Self.saveFolder(), since: began.addingTimeInterval(-2))
            if let url = found {
                finished?.url = url
                center.update(.recording) { $0.fileURL = url }
                scheduleClear()
                return
            }
            guard tries < 30 else { scheduleClear(); return }
            let work = DispatchWorkItem { attempt() }
            locateWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        attempt()
    }

    private static func newestRecording(in folder: URL, since: Date) -> URL? {
        let keys: [URLResourceKey] = [.creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return nil }
        return files
            .filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .compactMap { url -> (URL, Date)? in
                guard let d = try? url.resourceValues(forKeys: Set(keys)).creationDate, d >= since else { return nil }
                return (url, d)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// 완료 화면은 잠시 뒤 비운다 (열린 녹화 화면도 그때 닫힘)
    private func scheduleClear() {
        clearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finished = nil }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func revealFinished() {
        guard let f = finished else { return }
        if let url = f.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(f.folder) }
    }

    /// 시스템 녹화 중인지.
    /// ⌘⇧5 녹화 동안 macOS 스크린샷 도구는 화면 전체 크기의 창(메뉴바 층)을 띄워 두고, 녹화 방식을 고르는
    /// 아래쪽 도구 막대는 녹화를 시작하면 사라진다. 그래서 '전체 화면 창 + 도구 막대 없음'이면 녹화 시작으로 보고,
    /// 녹화 중에는 ⌘⇧5로 도구 막대를 다시 띄워도 전체 화면 창이 남아 있는 동안 녹화가 이어진 것으로 본다.
    /// (화면을 늘 캡처하는 다른 앱이 있는 Mac도 있어 '캡처 중 + 도구 실행'만으로는 스크린샷 뒤에도 녹화로 오인한다)
    /// 명령줄 녹화(screencapture -v)는 창이 없으므로 그 프로세스의 실행 인자로 확인한다.
    static func systemIsRecording(alreadyRecording: Bool = false,
                                  procs: (ui: Bool, cliVideo: Bool) = recorderProcesses()) -> Bool {
        if procs.ui {
            let ui = captureUI()
            if ui.fullScreenLayer && (!ui.toolbar || alreadyRecording) { return true }
            if ui.stopButton { return true }   // 예전 macOS: 메뉴바 정지 버튼
        }
        if procs.cliVideo, screenWatcherPresent?() ?? true { return true }
        return false
    }

    /// 스크린샷 도구 창 상태: 화면 전체 크기 창, 아래쪽 도구 막대, (예전 macOS의) 메뉴바 정지 버튼
    private static func captureUI() -> (fullScreenLayer: Bool, toolbar: Bool, stopButton: Bool) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return (false, false, false)
        }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let screens = NSScreen.screens.map(\.frame.size)
        var full = false, toolbar = false, stop = false
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            guard ["screencaptureui", "Screenshot", "스크린샷", "QuickTime Player"].contains(owner),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let width = b["Width"] ?? 0, height = b["Height"] ?? 0, y = b["Y"] ?? 0
            if screens.contains(where: { abs($0.width - width) < 2 && abs($0.height - height) < 2 }) { full = true }
            else if height >= 50 && height <= 140 && width >= 300 && layer > statusLevel { toolbar = true }
            else if layer >= statusLevel && y <= 2 && height <= 44 && width <= 220 { stop = true }
        }
        return (full, toolbar, stop)
    }

    /// 녹화 도구 프로세스: (screencaptureui·QuickTime 실행 중, 동영상 옵션으로 실행된 screencapture)
    /// 내 사용자 프로세스 목록을 sysctl 한 번으로 받아 이름만 본다 (프로세스마다 묻지 않아 가볍다).
    static func recorderProcesses() -> (ui: Bool, cliVideo: Bool) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return (false, false) }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return (false, false) }
        var ui = false, cli = false
        for p in procs.prefix(size / stride) {
            let name = withUnsafeBytes(of: p.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            switch name {
            case "screencaptureui", "QuickTime Player": ui = true
            case "screencapture":
                let args = processArguments(p.kp_proc.p_pid)
                if args.contains(where: { $0 == "-v" || $0 == "-V" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("v")) }) { cli = true }
            default: break
            }
        }
        return (ui, cli)
    }

    /// 다른 프로세스의 실행 인자 (같은 사용자 프로세스만 읽을 수 있음)
    private static func processArguments(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        // [argc][실행 파일 경로]\0...[인자1]\0[인자2]\0...
        var parts = buf[4..<size].split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        guard !parts.isEmpty else { return [] }
        parts.removeFirst()   // 실행 파일 경로
        return Array(parts.prefix(argc))
    }


    /// 녹화 정지·저장: 시스템 녹화 정지 단축키 ⌃⌘Esc (손쉬운 사용 권한 필요). macOS가 파일을 저장한다.
    func stop() {
        guard startedAt != nil else { return }
        stopRequested = true
        finished = nil
        let esc: CGKeyCode = 53
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: esc, keyDown: down)
            e?.flags = [.maskCommand, .maskControl]
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.poll() }
    }
}

/// 확장 상태의 화면 녹화 페이지.
/// 녹화 중: 빨간 정지 아이콘(누르면 정지·저장)과 녹화 시간. 끝나면: '녹화 완료'와 저장 위치를 여는 버튼.
struct RecordingPage: View {
    @ObservedObject var monitor: RecordingMonitor

    var body: some View {
        if let since = monitor.startedAt {
            VStack(spacing: 8) {
                Button { monitor.stop() } label: {
                    ZStack {
                        Circle().fill(Color.red.opacity(0.9))
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.white).frame(width: 14, height: 14)
                    }
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(T("녹화 중지·저장", "Stop and save recording"))
                Text(T("화면 녹화 중 · 아이콘을 누르면 저장", "Recording · click to stop and save"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                CallDurationText(since: since, font: .system(size: 22, weight: .semibold, design: .rounded))
            }
        } else if let done = monitor.finished {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.green)
                    Text(T("녹화 완료", "Recording Saved")).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
                if let url = done.url {
                    Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(T("저장 중…", "Saving…")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                Button { monitor.revealFinished() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.blue)
                        Text(T("Finder에서 보기", "Show in Finder")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        Spacer(minLength: 0)
                        Text(done.folder.lastPathComponent).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.1), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
