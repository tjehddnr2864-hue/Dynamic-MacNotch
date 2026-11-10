import AppKit
import ApplicationServices
import SwiftUI

/// iPhone 전화(연속성)·FaceTime 오디오 통화를 노치에 표시하고 받기·거절·끊기·음소거를 한다.
///
/// 두 경로를 함께 쓴다.
/// ① TelephonyUtilities(비공개): 통화 상태·이름·음소거를 알림으로 받는다. 시스템이 이 앱에 정보를 주지 않으면 비어 있다.
/// ② 손쉬운 사용: macOS가 띄우는 수신 배너(알림 센터)와 전화/FaceTime 앱 창의 버튼을 이름으로 찾아 누른다.
/// 평소에는 창이 새로 생길 때만 깨어나고(이벤트), 통화가 있는 동안에만 1초마다 상태를 확인한다.
final class CallMonitor: ObservableObject {
    enum State: Equatable {
        case idle
        case incoming(name: String)
        case active(name: String, since: Date, muted: Bool)
    }

    @Published private(set) var state: State = .idle
    /// 수신 카드를 두 손가락으로 올려 접었는지 (전화는 계속 울림)
    @Published private(set) var incomingMinimized = false

    private let center: ActivityCenter
    private let settings = AppSettings.shared

    // ① TelephonyUtilities
    private var tuCenter: NSObject?
    // ② 손쉬운 사용
    private var observers: [pid_t: AXObserver] = [:]
    private var pollTimer: Timer?
    private var axIncoming: (accept: AXControl?, decline: AXControl?)?
    private var axActive: (end: AXControl?, mute: AXControl?)?
    private var activeSince: Date?
    private var lastName = ""
    /// 마지막 손쉬운 사용 확인에서 통화와 관련된 창이 있었는지
    private var axSawCall = false

    private static let bannerApps = ["com.apple.notificationcenterui"]
    private static let callApps = ["com.apple.mobilephone", "com.apple.FaceTime"]

    init(center: ActivityCenter) {
        self.center = center
    }

    func start() {
        startTelephony()
        startAccessibility()
    }

    // MARK: - 사용자 동작

    // MARK: - 미리보기 (설정 → 테스트)
    // 가짜 통화를 띄운다. 미리보기 중에는 실제 통화 확인이 상태를 덮어쓰지 않고, 버튼은 가짜 통화만 바꾼다.
    // 30초 동안 조작이 없거나 끝내면 예약 작업·타이머를 모두 취소하고 실제 상태로 돌아간다.

    private(set) var previewActive = false
    private var previewEnd: DispatchWorkItem?

    func startPreview(incoming: Bool) {
        previewActive = true
        pollTimer?.invalidate()
        pollTimer = nil
        let name = "010-0000-0000"   // 저장되지 않은 번호로 걸려 온 경우
        setState(incoming ? .incoming(name: name) : .active(name: name, since: Date(), muted: false))
        schedulePreviewEnd()
    }

    func stopPreview() {
        guard previewActive else { return }
        previewEnd?.cancel()
        previewEnd = nil
        previewActive = false
        setState(.idle)
        refresh()   // 실제 통화가 있으면 다시 표시
    }

    private func schedulePreviewEnd() {
        previewEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopPreview() }
        previewEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// 미리보기 중 버튼 동작 (실제 통화에는 손대지 않음). 처리했으면 true.
    private func previewAction(_ action: String) -> Bool {
        guard previewActive else { return false }
        switch (action, state) {
        case ("answer", .incoming(let name)): setState(.active(name: name, since: Date(), muted: false))
        case ("mute", .active(let n, let s, let m)): setState(.active(name: n, since: s, muted: !m))
        case ("decline", _), ("hangup", _): stopPreview(); return true
        default: break
        }
        schedulePreviewEnd()
        return true
    }

    func answer() {
        if previewAction("answer") { return }
        if let call = tuIncomingCall(), let tu = tuCenter {
            tu.perform(NSSelectorFromString("answerCall:"), with: call)
        }
        // 시스템이 받기를 허용하지 않았으면 배너의 '수락' 버튼을 누른다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, case .incoming = self.state else { return }
            self.axIncoming?.accept?.press()
            self.refreshSoon()
        }
        incomingMinimized = false
    }

    func decline() {
        if previewAction("decline") { return }
        if let call = tuIncomingCall(), let tu = tuCenter {
            tu.perform(NSSelectorFromString("disconnectCall:"), with: call)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, case .incoming = self.state else { return }
            self.axIncoming?.decline?.press()
            self.refreshSoon()
        }
    }

    func hangUp() {
        if previewAction("hangup") { return }
        if let call = tuCurrentCalls().first, let tu = tuCenter {
            tu.perform(NSSelectorFromString("disconnectCall:"), with: call)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, case .active = self.state else { return }
            self.axActive?.end?.press()
            self.refreshSoon()
        }
    }

    func toggleMute() {
        if previewAction("mute") { return }
        guard case .active(let name, let since, let muted) = state else { return }
        if let call = tuCurrentCalls().first, call.responds(to: NSSelectorFromString("setUplinkMuted:")) {
            call.setValue(!muted, forKey: "uplinkMuted")
        }
        axActive?.mute?.press()
        // 화면은 바로 바꾸고, 다음 확인에서 실제 상태로 맞춘다
        setState(.active(name: name, since: since, muted: !muted))
        refreshSoon()
    }

    /// 수신 카드를 두 손가락으로 위로 올림: 거절하지 않고 작은 표시로 접는다.
    func minimizeIncoming() {
        guard case .incoming = state else { return }
        if previewActive { schedulePreviewEnd() }
        incomingMinimized = true
        publish()
    }

    func expandIncoming() {
        guard case .incoming = state else { return }
        incomingMinimized = false
        publish()
    }

    // MARK: - ① TelephonyUtilities

    private func startTelephony() {
        guard dlopen("/System/Library/PrivateFrameworks/TelephonyUtilities.framework/TelephonyUtilities", RTLD_LAZY) != nil,
              let cls = NSClassFromString("TUCallCenter") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("sharedInstance")) else { return }
        tuCenter = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
        for name in ["TUCallCenterCallStatusChangedNotification", "TUCallCenterCallConnectedNotification",
                     "TUCallIsUplinkMutedChangedNotification"] {
            NotificationCenter.default.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    private func tuCurrentCalls() -> [NSObject] {
        (tuCenter?.value(forKey: "currentCalls") as? [NSObject]) ?? []
    }

    private func tuIncomingCall() -> NSObject? {
        tuCenter?.value(forKey: "incomingCall") as? NSObject
    }

    /// TelephonyUtilities가 아는 통화 상태 (모르면 nil)
    private func tuState() -> State? {
        guard let call = tuCurrentCalls().first else { return nil }
        func v(_ k: String) -> Any? { call.responds(to: NSSelectorFromString(k)) ? call.value(forKey: k) : nil }
        let status = (v("status") as? Int) ?? 0
        let name = (v("displayName") as? String) ?? (v("suggestedDisplayName") as? String) ?? ""
        let incoming = (v("isIncoming") as? Bool) ?? false
        switch status {
        case 4 where incoming:   // 울리는 중
            return .incoming(name: name)
        case 1, 2, 3:            // 통화 중·대기·거는 중
            let connected = (v("dateConnected") as? Date) ?? activeSince ?? Date()
            return .active(name: name, since: connected, muted: (v("isUplinkMuted") as? Bool) ?? false)
        default:
            return nil
        }
    }

    // MARK: - ② 손쉬운 사용

    private func startAccessibility() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.watch(app)
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observers[app.processIdentifier] = nil
            self?.refreshSoon()
        }
        for app in NSWorkspace.shared.runningApplications { watch(app) }
    }

    /// 알림 배너·전화 앱의 창이 생기거나 사라질 때만 깨어난다.
    private func watch(_ app: NSRunningApplication) {
        guard AXIsProcessTrusted(), let id = app.bundleIdentifier,
              (Self.bannerApps + Self.callApps).contains(id), observers[app.processIdentifier] == nil else { return }
        let pid = app.processIdentifier
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, note, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<CallMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // 요소가 사라졌다는 알림은 통화가 끝났는지 볼 때만 쓴다. 통화가 없을 때는 위젯·배너가 바뀔 때마다 오므로 건너뛴다.
            if monitor.state == .idle, (note as String) == kAXUIElementDestroyedNotification { return }
            monitor.refreshSoon()
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for note in [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification, kAXCreatedNotification] {
            AXObserverAddNotification(observer, element, note as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        if Self.callApps.contains(id) { refreshSoon() }
    }

    private var burstActive = false
    private var burstGeneration = 0

    /// 창·요소가 생겼다는 알림을 받으면 바로 확인하고, 배너 안의 버튼·이름이 늦게 채워지는 경우를 위해
    /// 짧게 몇 번 더 확인한다 (상태가 바뀌면 그만). 알림이 연달아 와도 한 묶음만 돈다.
    /// (예약 작업이 자기 자신을 붙잡지 않도록 세대 번호로만 구분한다)
    func refreshSoon() {
        guard !burstActive else { return }
        burstActive = true
        burstGeneration &+= 1
        let generation = burstGeneration
        let before = state
        let delays: [TimeInterval] = [0, 0.1, 0.25, 0.5, 0.8, 1.2]
        for (i, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.burstActive, self.burstGeneration == generation else { return }
                // 상태가 바뀌었으면 남은 확인은 건너뛴다 (통화 중에는 1초 확인 타이머가 따로 돈다)
                if delay > 0, self.state != before { self.burstActive = false; return }
                if i == delays.count - 1 { self.burstActive = false }
                self.refresh()
                // 두 번 확인해도 통화와 관련된 창이 없으면(다른 알림 배너) 남은 확인은 건너뛴다
                if i >= 1, self.state == .idle, !self.axSawCall { self.burstActive = false }
            }
        }
    }

    /// 손쉬운 사용으로 본 통화 상태
    private func axState() -> State? {
        axIncoming = nil
        axActive = nil
        axSawCall = false
        guard AXIsProcessTrusted() else { return nil }
        // 수신 배너: '수락/받기' 버튼이 있는 알림
        for app in running(Self.bannerApps + Self.callApps) {
            for window in AXControl.windows(of: app.processIdentifier) {
                let found = AXControl.search(window)
                if found.callContext { axSawCall = true }
                if found.accept != nil {
                    axIncoming = (found.accept, found.decline)
                    return .incoming(name: found.name ?? lastName)
                }
                if found.end != nil {
                    axActive = (found.end, found.mute)
                    let since = activeSince ?? Date()
                    return .active(name: found.name ?? lastName, since: since, muted: found.muted ?? currentMuted)
                }
            }
        }
        return nil
    }

    private var currentMuted: Bool {
        if case .active(_, _, let m) = state { return m }
        return false
    }

    private func running(_ ids: [String]) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { ids.contains($0.bundleIdentifier ?? "") }
    }

    // MARK: - 상태 갱신

    func refresh() {
        if previewActive { return }   // 미리보기 중에는 가짜 통화를 유지
        guard settings.callEnabled else { setState(.idle); return }
        let new = tuState() ?? axState() ?? .idle
        setState(new)
        // 통화가 있는 동안에만 1초마다 확인 (통화 시간·음소거·종료 감지)
        if new == .idle {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            pollTimer = t
        }
    }

    private func setState(_ new: State) {
        var new = new
        switch new {
        case .incoming(let name):
            if !name.isEmpty { lastName = name }
            activeSince = nil
        case .active(let name, let since, let muted):
            if !name.isEmpty { lastName = name }
            if activeSince == nil { activeSince = since }
            new = .active(name: name.isEmpty ? lastName : name, since: activeSince ?? since, muted: muted)
            incomingMinimized = false
        case .idle:
            activeSince = nil
            incomingMinimized = false
        }
        guard new != state else { return }
        let wasIncoming: Bool = { if case .incoming = state { return true }; return false }()
        state = new
        if wasIncoming, case .incoming = new {} else if wasIncoming { center.dismissTransient(kind: .call) }
        publish()
        if case .idle = new { lastName = "" }
    }

    private func publish() {
        switch state {
        case .idle:
            center.removePersistent(.call)
            center.dismissTransient(kind: .call)
        case .incoming(let name):
            center.removePersistent(.call)
            let display = name.isEmpty ? T("전화", "Phone") : name
            if incomingMinimized {
                center.dismissTransient(kind: .call)
                center.setPersistent(NotchActivity(
                    kind: .call, priority: ActivityPriority.call, symbol: "phone.fill", tint: .green,
                    value: .text(T("수신", "Ringing")), title: display, wing: NotchActivity.compactWing))
            } else {
                center.post(NotchActivity(
                    kind: .call, priority: ActivityPriority.call, presentation: .detail, duration: 120,
                    symbol: "phone.fill", tint: .green, value: .none,
                    title: display, subtitle: T("수신 전화", "Incoming Call"), detailHeight: 64))
            }
        case .active(let name, let since, let muted):
            center.dismissTransient(kind: .call)
            center.setPersistent(NotchActivity(
                kind: .call, priority: ActivityPriority.call, symbol: "phone.fill", tint: .green,
                value: .waveform(!muted), title: name.isEmpty ? T("통화 중", "On Call") : name,
                subtitle: muted ? T("음소거됨", "Muted") : nil, wing: NotchActivity.compactWing, startDate: since))
        }
    }

}
