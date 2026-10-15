import AppKit
import SwiftUI

/// 화면 녹화 실시간 표시 (가이드라인 5.10).
/// 시스템 녹화(⌘⇧5, QuickTime) 중 메뉴바에 뜨는 정지 버튼 창을 1초마다 찾아 녹화 여부를 추정한다.
final class RecordingMonitor: ObservableObject {
    @Published private(set) var startedAt: Date?
    @Published var tick = Date()

    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private var timer: Timer?

    init(center: ActivityCenter) {
        self.center = center
    }

    /// 녹화를 할 수 있는 앱(스크린샷 UI, QuickTime)이 실행 중일 때만 1초 확인을 돌린다.
    /// 둘 다 꺼져 있으면 녹화 중일 수 없으므로 아무것도 하지 않는다 (idle CPU 0).
    private static let recorderApps: Set<String> = ["com.apple.screencaptureui", "com.apple.QuickTimePlayerX"]

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let id = app?.bundleIdentifier, Self.recorderApps.contains(id) else { return }
                self?.updatePolling()
            }
        }
        updatePolling()
    }

    private func updatePolling() {
        let running = NSWorkspace.shared.runningApplications.contains { Self.recorderApps.contains($0.bundleIdentifier ?? "") }
        if running, timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !running {
            timer?.invalidate()
            timer = nil
            if startedAt != nil { stopped() }
        }
    }

    var elapsed: TimeInterval { startedAt.map { tick.timeIntervalSince($0) } ?? 0 }

    private func poll() {
        guard settings.recordingEnabled else {
            if startedAt != nil { stopped() }
            return
        }
        let recording = Self.systemIsRecording()
        if recording, startedAt == nil {
            startedAt = Date()
        } else if !recording, startedAt != nil {
            stopped()
            return
        }
        guard startedAt != nil else { return }
        tick = Date()
        center.setPersistent(NotchActivity(
            kind: .recording, priority: ActivityPriority.recording,
            symbol: "record.circle.fill", tint: .red,
            value: .text(TimerController.format(elapsed)),
            title: T("화면 녹화", "Screen Recording"), wing: 58
        ))
    }

    private func stopped() {
        startedAt = nil
        center.removePersistent(.recording)
    }

    /// 녹화 중 표시: screencaptureui / QuickTime이 메뉴바 높이(상태 레벨)에 띄운 작은 창.
    static func systemIsRecording() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard ["screencaptureui", "QuickTime Player", "Screenshot", "스크린샷"].contains(owner),
                  layer >= statusLevel,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let h = b["Height"], let y = b["Y"], let width = b["Width"] else { continue }
            if y <= 1, h <= 40, width <= 60 { return true }
        }
        return false
    }

    /// 시스템 녹화 정지 단축키 ⌘⌃Esc를 보낸다 (손쉬운 사용 권한 필요).
    func stop() {
        let esc: CGKeyCode = 53
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: esc, keyDown: down)
            e?.flags = [.maskCommand, .maskControl]
            e?.post(tap: .cghidEventTap)
        }
    }
}

/// 확장 상태의 화면 녹화 페이지.
struct RecordingPage: View {
    @ObservedObject var monitor: RecordingMonitor

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                RecordingDot()
                Text(T("화면 녹화 중", "Recording Screen")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
            Text(TimerController.format(monitor.elapsed))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Button { monitor.stop() } label: {
                Label(T("정지", "Stop"), systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }
}
