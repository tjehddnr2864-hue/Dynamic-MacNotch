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
    private static let recorderProcesses: Set<String> = ["screencaptureui", "screencapture", "QuickTime Player"]

    init(center: ActivityCenter) {
        self.center = center
    }

    func start() {
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let recording = settings.recordingEnabled && Self.systemIsRecording()
        if recording, startedAt == nil {
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
        finished = Finished(date: Date(), url: nil, folder: Self.saveFolder())
        locateSavedFile(since: began)
        center.removePersistent(.recording)
        center.dismissTransient(kind: .recording)
        let text = stopRequested ? T("저장됨", "Saved") : T("녹화 종료", "Ended")
        stopRequested = false
        center.post(NotchActivity(kind: .recording, duration: 2.5, symbol: "checkmark.circle.fill", tint: .green,
                                  value: .text(text), title: T("화면 녹화", "Screen Recording"), wing: NetworkMonitor.wing(for: text)))
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
            if let url = Self.newestRecording(in: current.folder, since: began.addingTimeInterval(-2)) {
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

    /// 시스템 녹화 중인지
    static func systemIsRecording() -> Bool {
        if let watcher = screenWatcherPresent {
            return watcher() && recorderRunning()
        }
        return recorderRunning() && recordingIndicatorWindowVisible()   // SkyLight 함수를 못 쓰면 메뉴바 정지 버튼 창으로 추정
    }

    private static func recorderRunning() -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var name = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            if proc_name(pid, &name, UInt32(name.count)) > 0, recorderProcesses.contains(String(cString: name)) { return true }
        }
        return false
    }

    private static func recordingIndicatorWindowVisible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        return list.contains { w in
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard ["screencaptureui", "QuickTime Player"].contains(owner), layer >= statusLevel,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (b["Y"] ?? 99) <= 1 && (b["Height"] ?? 99) <= 40 && (b["Width"] ?? 99) <= 60
        }
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
