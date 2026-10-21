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
        let name = T("김민지", "Alex Kim")
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
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<CallMonitor>.fromOpaque(refcon).takeUnretainedValue().refreshSoon()
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

    private var pendingRefresh: DispatchWorkItem?

    func refreshSoon() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 손쉬운 사용으로 본 통화 상태
    private func axState() -> State? {
        axIncoming = nil
        axActive = nil
        guard AXIsProcessTrusted() else { return nil }
        // 수신 배너: '수락/받기' 버튼이 있는 알림
        for app in running(Self.bannerApps + Self.callApps) {
            for window in AXControl.windows(of: app.processIdentifier) {
                let found = AXControl.search(window)
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

    #if DEV
    /// 개발용: 가짜 통화 상태 ("incoming|이름", "active|이름", "mute", "idle")
    func debugSimulate(_ spec: String) {
        let p = spec.split(separator: "|").map(String.init)
        switch p.first {
        case "incoming": setState(.incoming(name: p.count > 1 ? p[1] : "Test"))
        case "active": setState(.active(name: p.count > 1 ? p[1] : "Test", since: Date(), muted: false))
        case "min": minimizeIncoming()
        case "mute":
            if case .active(let n, let s, let m) = state { setState(.active(name: n, since: s, muted: !m)) }
        default: setState(.idle)
        }
    }
    #endif
}

// MARK: - 손쉬운 사용 요소

/// 누를 수 있는 손쉬운 사용 요소 (버튼 또는 이름 붙은 동작)
struct AXControl {
    let element: AXUIElement
    let action: String

    func press() { AXUIElementPerformAction(element, action as CFString) }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }

    private static let acceptWords = ["수락", "받기", "응답", "accept", "answer"]
    private static let declineWords = ["거절", "decline", "reject"]
    private static let endWords = ["끊기", "통화 종료", "종료", "end call", "end", "hang up"]
    /// macOS 통화 배너의 음소거 버튼은 '소리 끔'(음소거 해제 상태에서는 '소리 켬')으로 나온다
    private static let muteWords = ["음소거", "소리 끔", "소리 켬", "mute", "unmute"]
    private static let unmuteWords = ["소리 켬", "음소거 해제", "unmute"]
    /// '거절하고 메시지 보내기' 같은 다른 거절 버튼은 건너뛴다
    private static let declineExclude = ["메시지", "message", "음성"]
    /// 이름 후보에서 뺄 글자 (앱·버튼 이름 등)
    private static let noise = ["전화", "phone", "facetime", "수신 전화", "incoming call", "오디오", "audio", "알림", "notification",
                                "휴대폰", "mobile", "iphone", "통화", "call"]

    struct Found {
        var accept: AXControl?, decline: AXControl?, end: AXControl?, mute: AXControl?
        var muted: Bool?
        var name: String?
        /// 배너 설명에서 읽은 상대 이름(저장된 연락처) 또는 전화번호
        var caller: String?
    }

    private static func rawDescription(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &v) == .success, let s = v as? String else { return nil }
        return s
    }

    /// "이름, 부가 설명 - 0:12" → "이름". 방향 표시 같은 보이지 않는 문자는 지운다.
    /// 부가 설명(iPhone으로부터 전달됨 등)이 붙은 칸만 상대 칸으로 본다.
    static func callerName(from description: String) -> String? {
        let invisible = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        let clean = String(description.unicodeScalars.filter { !invisible.contains($0) })
        let parts = clean.components(separatedBy: ", ")
        guard parts.count >= 2 else { return nil }
        let rest = parts.dropFirst().joined(separator: ", ").lowercased()
        guard ["iphone", "전달", "forward", "facetime", "휴대전화", "mobile", "전화", "phone"].contains(where: rest.contains) else { return nil }
        var name = parts[0].trimmingCharacters(in: .whitespaces)
        if let r = name.range(of: #" - \d+:\d{2}(:\d{2})?$"#, options: .regularExpression) { name.removeSubrange(r) }
        return name.isEmpty ? nil : name
    }

    /// 창 안에서 수락·거절·끊기·음소거 조작과 상대 이름을 찾는다.
    static func search(_ root: AXUIElement) -> Found {
        var found = Found()
        var texts: [String] = []
        var context = ""
        var visited = 0
        func label(_ el: AXUIElement) -> String {
            var parts: [String] = []
            for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXIdentifier"] {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let s = v as? String, !s.isEmpty { parts.append(s) }
            }
            return parts.joined(separator: " ").lowercased()
        }
        // 한글은 포함 여부로, 영어는 단어 단위로 (예: "end"가 "calendar"에 걸리지 않게)
        func matches(_ text: String, _ words: [String]) -> Bool {
            words.contains { w in
                if w.range(of: "[a-z]", options: .regularExpression) == nil { return text.contains(w) }
                return text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: w))\\b", options: .regularExpression) != nil
            }
        }
        func walk(_ el: AXUIElement, depth: Int) {
            visited += 1
            guard depth < 16, visited < 600 else { return }
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""
            var actionsRef: CFArray?
            AXUIElementCopyActionNames(el, &actionsRef)
            let actions = (actionsRef as? [String]) ?? []
            let text = label(el)
            context += " " + text
            // 버튼만 이름으로 분류 (상대 이름 칸도 누를 수 있는 요소라, 이름이 '응답센터'여도 버튼으로 보지 않게)
            if role == kAXButtonRole as String || role == "AXCheckBox" {
                if found.accept == nil, matches(text, acceptWords) { found.accept = AXControl(element: el, action: kAXPressAction) }
                else if matches(text, declineWords) {
                    if found.decline == nil, !matches(text, declineExclude) { found.decline = AXControl(element: el, action: kAXPressAction) }
                } else if found.mute == nil, matches(text, muteWords) {
                    found.mute = AXControl(element: el, action: kAXPressAction)
                    var v: CFTypeRef?
                    if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let n = v as? NSNumber {
                        found.muted = n.boolValue
                    } else {
                        found.muted = matches(text, unmuteWords)   // '소리 켬'이 보이면 지금 음소거 상태
                    }
                } else if found.end == nil, matches(text, endWords) { found.end = AXControl(element: el, action: kAXPressAction) }
            } else if found.caller == nil, let desc = rawDescription(el), let caller = Self.callerName(from: desc) {
                // 통화 배너의 상대 칸: "홍길동, iPhone으로부터 전달됨" / "‪010-0000-0000‬, iPhone으로부터 전달됨 - 0:12"
                found.caller = caller
            }
            // 알림 배너의 사용자 정의 동작 (예: "수락", "거절")
            for action in actions where !action.hasPrefix("AX") || action.contains("Name:") {
                let lower = action.lowercased()
                if found.accept == nil, matches(lower, acceptWords) { found.accept = AXControl(element: el, action: action) }
                if found.decline == nil, matches(lower, declineWords) { found.decline = AXControl(element: el, action: action) }
            }
            // 이름 후보: 짧은 글자(정적 텍스트·설명)
            if role == kAXStaticTextRole as String || role == "AXHeading" {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let s = v as? String { texts.append(s) }
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            for c in (children as? [AXUIElement]) ?? [] { walk(c, depth: depth + 1) }
        }
        walk(root, depth: 0)
        // 캘린더 초대처럼 '수락/거절'이 있는 다른 알림은 통화로 보지 않는다
        let callContext = ["전화", "통화", "facetime", "phone", "call"].contains { (context + " " + texts.joined(separator: " ").lowercased()).contains($0) }
        if !callContext { found.accept = nil; found.decline = nil; found.end = nil; found.mute = nil }
        found.name = found.caller ?? texts.first { t in
            let l = t.lowercased().trimmingCharacters(in: .whitespaces)
            return !l.isEmpty && l.count <= 40 && !noise.contains(l) && !l.contains(":") && l.rangeOfCharacter(from: .letters) != nil
        }
        return found
    }
}
