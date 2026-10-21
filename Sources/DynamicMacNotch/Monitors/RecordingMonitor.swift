import AppKit
import SwiftUI

/// 화면 녹화 표시 (⌘⇧5, QuickTime 등 시스템 녹화).
/// 1.5초마다 '화면을 캡처하는 쪽이 있는지'(SkyLight, 매우 가벼운 호출)만 보고,
/// 있을 때만 녹화 도구(screencaptureui·QuickTime) 프로세스가 떠 있는지 확인해 녹화로 판단한다.
/// (screencaptureui는 '앱'으로 실행되지 않아 앱 실행 알림으로는 알 수 없다)
final class RecordingMonitor: ObservableObject {
    @Published private(set) var startedAt: Date?

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
            // 계속 표시: 왼쪽 녹화 시간, 오른쪽 깜빡이는 빨간 점 (왼쪽을 누르면 정지)
            center.setPersistent(NotchActivity(
                kind: .recording, priority: ActivityPriority.recording, symbol: "record.circle.fill", tint: .red,
                value: .recordingDot, title: T("화면 녹화", "Screen Recording"), wing: NotchActivity.compactWing, startDate: now))
        } else {
            // 잠깐 알림 후 들어감
            center.post(NotchActivity(
                kind: .recording, priority: ActivityPriority.recording, duration: 3, symbol: "record.circle.fill", tint: .red,
                value: .text(T("녹화 시작", "Recording")), title: T("화면 녹화", "Screen Recording"),
                wing: NetworkMonitor.wing(for: T("녹화 시작", "Recording"))))
        }
    }

    private func stopped() {
        startedAt = nil
        center.removePersistent(.recording)
        center.dismissTransient(kind: .recording)
        let text = stopRequested ? T("저장됨", "Saved") : T("녹화 종료", "Ended")
        stopRequested = false
        center.post(NotchActivity(kind: .recording, duration: 2.5, symbol: "checkmark.circle.fill", tint: .green,
                                  value: .text(text), title: T("화면 녹화", "Screen Recording"), wing: NetworkMonitor.wing(for: text)))
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
        let esc: CGKeyCode = 53
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: esc, keyDown: down)
            e?.flags = [.maskCommand, .maskControl]
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.poll() }
    }
}

/// 확장 상태의 화면 녹화 페이지. 빨간 녹화 아이콘을 누르면 녹화가 멈추고 저장된다.
struct RecordingPage: View {
    @ObservedObject var monitor: RecordingMonitor

    var body: some View {
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
            if let since = monitor.startedAt {
                CallDurationText(since: since, font: .system(size: 22, weight: .semibold, design: .rounded))
            }
        }
    }
}
