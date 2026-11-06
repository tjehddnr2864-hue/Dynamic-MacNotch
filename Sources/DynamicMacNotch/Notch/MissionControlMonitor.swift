import AppKit

/// Mission Control이 열려 있는지 알려 준다.
/// 공개 API가 없어 창 목록으로 판정한다: Mission Control은 WindowManager가 화면 폭만 한 'Spaces Bar'(레벨 14)를 만든다.
/// 앱 Exposé는 같은 쉴드 창을 쓰지만 이 막대가 없고, 바탕화면 보기는 다른 창을 쓴다.
/// 창 이름은 화면 기록 권한이 없으면 비어 오므로 소유자·레벨·크기만 본다.
///
/// 평소에는 폴링하지 않는다. 창 서버 이벤트(비공개)는 "다시 확인하라"는 신호로만 쓰고, 상태는 항상 창 목록으로 정한다.
/// 이벤트가 오지 않는 macOS에서도 안전 점검이 바로잡는다.
final class MissionControlMonitor {
    private(set) var isActive = false
    /// 상태가 바뀔 때 메인 스레드에서 불린다
    var onChange: ((Bool) -> Void)?

    /// macOS 27.3에서 Mission Control을 열고 닫을 때 오는 번호. 평소에는 오지 않는다.
    private static let wakeEvents: [UInt32] = [1325, 1326, 1508]
    /// 이벤트가 창보다 먼저 오므로 그 뒤로 한동안 확인한다
    private static let settleTime: TimeInterval = 1.2
    private static let fastInterval: TimeInterval = 0.1
    private static let safetyInterval: TimeInterval = 3
    private static let fallbackInterval: TimeInterval = 0.5
    /// 빠르게 열고 닫을 때 깜빡이지 않게, 사라진 것이 이만큼 연속으로 확인되어야 끝난 것으로 본다
    private static let absentChecksToEnd = 2

    private static weak var current: MissionControlMonitor?

    private var fastTimer: Timer?
    private var safetyTimer: Timer?
    private var settleUntil = Date.distantPast
    private var lastEvent = Date.distantPast
    private var absentCount = 0
    private var eventsTrusted = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        Self.current = self
        eventsTrusted = registerEvents()
        scheduleSafetyTimer()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.kick() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in self?.kick() })
        check()   // 앱이 Mission Control 중에 켜진 경우
    }

    // MARK: - 판정

    /// 창 목록을 한 번 읽는다 (약 0.2ms)
    static func isShowing() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let screens = NSScreen.screens.map(\.frame.size)
        return list.contains { window in
            guard window[kCGWindowOwnerName as String] as? String == "WindowManager",
                  window[kCGWindowLayer as String] as? Int == 14,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"] else { return false }
            return screens.contains { abs($0.width - width) < 1 && height < $0.height / 2 }
        }
    }

    private func check() {
        if Self.isShowing() {
            absentCount = 0
            if !isActive {
                // 이벤트 없이 안전 점검이 먼저 찾았으면 이 macOS에서는 이벤트를 믿지 않고 더 자주 확인한다
                if eventsTrusted, Date().timeIntervalSince(lastEvent) > Self.safetyInterval + 2 {
                    eventsTrusted = false
                    scheduleSafetyTimer()
                }
                setActive(true)
            }
        } else if isActive {
            absentCount += 1
            if absentCount >= Self.absentChecksToEnd { setActive(false) }
        }
        updateFastTimer()
    }

    private func setActive(_ active: Bool) {
        absentCount = 0
        guard active != isActive else { return }
        isActive = active
        onChange?(active)
    }

    // MARK: - 타이머

    /// 지금부터 한동안 자주 확인한다
    private func kick() {
        settleUntil = Date().addingTimeInterval(Self.settleTime)
        check()
    }

    /// 빠른 확인은 이벤트 직후와 Mission Control이 열려 있는 동안에만 돈다
    private func updateFastTimer() {
        let needed = isActive || Date() < settleUntil
        if needed, fastTimer == nil {
            let timer = Timer(timeInterval: Self.fastInterval, repeats: true) { [weak self] _ in self?.check() }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            fastTimer = timer
        } else if !needed {
            fastTimer?.invalidate()
            fastTimer = nil
        }
    }

    private func scheduleSafetyTimer() {
        safetyTimer?.invalidate()
        let interval = eventsTrusted ? Self.safetyInterval : Self.fallbackInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
    }

    // MARK: - 창 서버 이벤트 (비공개, 실패해도 안전 점검으로 동작)

    private typealias EventProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
    private typealias RegisterFunction = @convention(c) (EventProc, UInt32, UnsafeMutableRawPointer?) -> Int32

    private func registerEvents() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let symbol = dlsym(handle, "CGSRegisterNotifyProc") else { return false }
        let register = unsafeBitCast(symbol, to: RegisterFunction.self)
        let callback: EventProc = { _, _, _, _ in
            DispatchQueue.main.async {
                guard let monitor = MissionControlMonitor.current else { return }
                monitor.lastEvent = Date()
                monitor.kick()
            }
        }
        return Self.wakeEvents.reduce(true) { $0 && register(callback, $1, nil) == 0 }
    }
}
