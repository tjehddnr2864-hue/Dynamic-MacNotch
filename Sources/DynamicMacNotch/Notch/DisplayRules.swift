import Foundation

/// 디스플레이 하나가 놓인 상황 (NotchHub가 정한다)
struct DisplayContext: Equatable {
    var uuid: String
    /// 주 디스플레이. 노치를 켰는지와 상관없다.
    var main: String
    /// 노치를 켠 디스플레이 전부
    var enabled: [String]
}

/// 중요한 알림 목록의 한 줄. 일회성 알림 하나를 가리키며, 통화·녹화만 상시 표시에도 적용된다.
enum CriticalAlert {
    /// 놓치면 안 되는 알림의 기본 구성
    static let defaults: Set<String> = ["call", "timer", "calendar", "batteryLow", "recording"]
    /// 상시 표시까지 따라가는 항목 (실행 중 타이머·다운로드 진행 등은 따라가지 않는다)
    static let persistentForm: [ActivityKind] = [.call, .recording]
    /// 설정 화면의 표시 순서
    static let all = ["call", "timer", "calendar", "batteryLow", "recording", "agent", "chat", "update", "download", "airdrop",
                      "screenshot", "media", "bluetooth", "network", "vpn", "focus", "battery", "hud"]

    static func id(of activity: NotchActivity) -> String {
        if activity.kind == .battery, activity.priority == ActivityPriority.batteryLow { return "batteryLow" }
        return activity.kind.rawValue
    }

    static func label(_ id: String) -> String {
        switch id {
        case "call": return T("통화", "Phone Calls")
        case "timer": return T("타이머 완료", "Timer Done")
        case "calendar": return T("일정 알림", "Event Alerts")
        case "batteryLow": return T("배터리 부족", "Low Battery")
        case "recording": return T("화면 녹화 중", "Screen Recording")
        case "agent": return T("AI 에이전트 작업 완료", "AI Agent Finished")
        case "chat": return T("AI 채팅 답변 완료", "AI Chat Answer Ready")
        case "update": return T("업데이트 완료", "Update Finished")
        case "download": return T("다운로드 결과", "Download Results")
        case "airdrop": return T("에어드랍 결과", "AirDrop Results")
        case "screenshot": return T("스크린샷 카드", "Screenshot Card")
        case "media": return T("곡 변경", "Track Changes")
        case "bluetooth": return T("블루투스", "Bluetooth")
        case "network": return T("네트워크", "Network")
        case "vpn": return "VPN"
        case "focus": return T("집중 모드", "Focus")
        case "battery": return T("충전 시작·완료", "Charging Started / Finished")
        case "hud": return T("음량·밝기·키보드 백라이트", "Volume, Brightness, Keyboard Backlight")
        default: return id
        }
    }
}

/// 어느 디스플레이에 무엇을 보일지 정하는 규칙. 화면에 의존하지 않는 순수 계산이다 (가이드라인 3.6).
struct DisplayRules {
    var content: [String: String]
    var fallbackToMain: Bool
    var alertScopeAll: Bool
    var criticalEnabled: Bool
    var critical: Set<String>

    /// 이 디스플레이의 선택. "주 디스플레이를 따름"은 한 번만 따라가므로 순환하지 않는다.
    /// 주 디스플레이가 "노치 없음"이면 그것을 따르지 않고 모든 항목을 보인다.
    func choice(_ ctx: DisplayContext) -> String {
        let own = content[ctx.uuid] ?? (ctx.uuid == ctx.main ? DisplayChoice.all : DisplayChoice.followMain)
        guard own == DisplayChoice.followMain else { return own }
        return mainChoice(ctx)
    }

    private func mainChoice(_ ctx: DisplayContext) -> String {
        let main = content[ctx.main] ?? DisplayChoice.all
        return main == DisplayChoice.followMain || main == DisplayChoice.none ? DisplayChoice.all : main
    }

    private static func kind(in choice: String) -> ActivityKind? {
        choice.hasPrefix("kind:") ? ActivityKind(rawValue: String(choice.dropFirst(5))) : nil
    }

    /// 일회성 알림이 이 디스플레이에 뜨는지
    func alertReaches(_ activity: NotchActivity, _ ctx: DisplayContext) -> Bool {
        guard ctx.enabled.contains(ctx.uuid) else { return false }
        if criticalEnabled, critical.contains(CriticalAlert.id(of: activity)) { return true }
        if alertScopeAll || !ctx.enabled.contains(ctx.main) { return true }
        return ctx.uuid == ctx.main
    }

    /// 이 디스플레이에 보일 상시 표시 항목 (active는 지금 활성인 항목)
    func persistentKinds(_ ctx: DisplayContext, active: Set<ActivityKind>) -> Set<ActivityKind> {
        var kinds: Set<ActivityKind>
        let choice = self.choice(ctx)
        switch choice {
        case DisplayChoice.notchOnly:
            kinds = []
        case DisplayChoice.all, DisplayChoice.none:
            kinds = active
        default:
            if let kind = Self.kind(in: choice), active.contains(kind) {
                kinds = [kind]
            } else if fallbackToMain {
                kinds = mainResult(ctx, active: active)   // 선택한 항목이 비활성: 주 디스플레이의 결과를 한 번만 가져온다
            } else {
                kinds = []
            }
        }
        if criticalEnabled {
            for kind in CriticalAlert.persistentForm where active.contains(kind) && critical.contains(kind.rawValue) {
                kinds.insert(kind)
            }
        }
        return kinds
    }

    /// 주 디스플레이가 자기 선택으로 보이는 항목 (대체는 하지 않는다)
    private func mainResult(_ ctx: DisplayContext, active: Set<ActivityKind>) -> Set<ActivityKind> {
        let choice = mainChoice(ctx)
        if choice == DisplayChoice.all { return active }
        if let kind = Self.kind(in: choice), active.contains(kind) { return [kind] }
        return []
    }
}

#if DEV
/// 개발용: `--display-probe` 모든 조합을 돌려 규칙을 확인한다.
enum DisplayProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--display-probe") else { return }
        let main = "M", sub = "S"
        func activity(_ kind: ActivityKind, priority: Int = ActivityPriority.info) -> NotchActivity {
            NotchActivity(kind: kind, priority: priority, symbol: "x")
        }
        var checks = 0, failures: [String] = []
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            checks += 1
            if !ok { failures.append(what()) }
        }
        let choices = [DisplayChoice.all, DisplayChoice.kind("vpn"), DisplayChoice.notchOnly, DisplayChoice.none, DisplayChoice.followMain]
        let actives: [Set<ActivityKind>] = [[], [.media], [.vpn], [.vpn, .media], [.call, .media], [.recording], [.timer, .vpn]]
        for subChoice in choices {
            for mainChoice in choices where mainChoice != DisplayChoice.followMain {
                for fallback in [true, false] {
                    for scopeAll in [true, false] {
                        for criticalOn in [true, false] {
                            for active in actives {
                                let rules = DisplayRules(content: [main: mainChoice, sub: subChoice], fallbackToMain: fallback, alertScopeAll: scopeAll,
                                                         criticalEnabled: criticalOn, critical: CriticalAlert.defaults)
                                let enabled = [main, sub].filter { (rules.content[$0] ?? "") != DisplayChoice.none }
                                let name = "main=\(mainChoice) sub=\(subChoice) fb=\(fallback) scope=\(scopeAll) crit=\(criticalOn) active=\(active.map(\.rawValue).sorted())"
                                for uuid in enabled {
                                    let ctx = DisplayContext(uuid: uuid, main: main, enabled: enabled)
                                    let kinds = rules.persistentKinds(ctx, active: active)
                                    let criticalKinds = active.intersection([.call, .recording])
                                    check(kinds.isSubset(of: active), "subset \(name)")
                                    let choice = rules.choice(ctx)
                                    if criticalOn { check(criticalKinds.isSubset(of: kinds), "crit persistent \(name)") }
                                    if choice == DisplayChoice.notchOnly {
                                        check(kinds == (criticalOn ? criticalKinds : []), "notchOnly \(name)")
                                    }
                                    if choice == DisplayChoice.kind("vpn") {
                                        if active.contains(.vpn) {
                                            check(kinds.subtracting(criticalOn ? criticalKinds : []) == [.vpn], "kind active \(name)")
                                        } else if !fallback {
                                            check(kinds == (criticalOn ? criticalKinds : []), "kind inactive, fallback off \(name)")
                                        }
                                    }
                                    if uuid == sub, subChoice == DisplayChoice.kind("vpn"), !active.contains(.vpn), fallback {
                                        let mainCtx = DisplayContext(uuid: main, main: main, enabled: enabled)
                                        check(kinds == rules.persistentKinds(mainCtx, active: active), "fallback shows main \(name)")
                                    }
                                    // 알림: 중요 알림은 켠 디스플레이 전부, 나머지는 범위대로
                                    if criticalOn { check(rules.alertReaches(activity(.timer), ctx), "critical alert \(name)") }
                                    let reachesNormal = rules.alertReaches(activity(.bluetooth), ctx)
                                    check(reachesNormal == (scopeAll || !enabled.contains(main) || uuid == main), "normal alert \(name)")
                                }
                            }
                        }
                    }
                }
            }
        }
        // 요청하신 예: 서브를 VPN으로 두었을 때
        let both = [main, sub], subCtx = DisplayContext(uuid: sub, main: main, enabled: both)
        var rules = DisplayRules(content: [sub: DisplayChoice.kind("vpn")], fallbackToMain: true, alertScopeAll: false, criticalEnabled: true, critical: CriticalAlert.defaults)
        check(rules.persistentKinds(subCtx, active: [.media]) == [.media], "VPN off, fallback on shows main content")
        check(rules.persistentKinds(subCtx, active: [.vpn, .media]) == [.vpn], "VPN on shows VPN")
        rules.fallbackToMain = false
        check(rules.persistentKinds(subCtx, active: [.media]).isEmpty, "VPN off, fallback off shows plain notch")
        // 배터리 부족만 중요 알림이고 충전 시작은 아니다
        check(rules.alertReaches(activity(.battery, priority: ActivityPriority.batteryLow), subCtx), "low battery reaches sub")
        check(!rules.alertReaches(activity(.battery), subCtx), "charging does not reach sub")
        // 중요 알림 끔·기본 항목 제외
        rules.critical = CriticalAlert.defaults.subtracting(["timer"])
        check(!rules.alertReaches(activity(.timer), subCtx), "removed critical stays on main")
        rules.critical.insert("hud")
        check(rules.alertReaches(activity(.hud), subCtx), "added critical reaches sub")
        // 주 디스플레이가 "노치 없음": 따르는 쪽은 모든 항목을 보인다
        let followCtx = DisplayContext(uuid: sub, main: main, enabled: [sub])
        rules = DisplayRules(content: [main: DisplayChoice.none], fallbackToMain: true, alertScopeAll: false, criticalEnabled: true, critical: CriticalAlert.defaults)
        check(rules.persistentKinds(followCtx, active: [.media]) == [.media], "follow main when main has no notch")
        check(rules.alertReaches(activity(.bluetooth), followCtx), "alert moves when main has no notch")
        // 선택 규칙
        let conn = [main, sub]
        check(Displays.enabledUUIDs(selection: "all", content: [:], connected: conn) == conn, "all")
        check(Displays.enabledUUIDs(selection: "all", content: [sub: "none"], connected: conn) == [main], "all minus none")
        check(Displays.enabledUUIDs(selection: "all", content: [main: "none", sub: "none"], connected: conn) == [main], "never empty")
        check(Displays.enabledUUIDs(selection: "one:S", content: [:], connected: conn) == [sub], "one")
        print("checks=\(checks) failures=\(failures.count)")
        failures.prefix(10).forEach { print("  FAIL", $0) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
#endif
