import Foundation

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
