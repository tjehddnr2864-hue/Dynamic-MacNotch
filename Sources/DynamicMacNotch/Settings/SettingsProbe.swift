import Combine
import Foundation

#if DEV
/// 개발용: `--settings-probe` 설정 저장·다시 읽기·알림을 확인한다. 값은 끝나면 되돌린다.
enum SettingsProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--settings-probe") else { return }
        exit(run() ? 0 : 1)
    }

    private static func run() -> Bool {
        let settings = AppSettings.shared, d = UserDefaults.standard
        var checks = 0, failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures.append(what) }
        }
        let saved = (d.object(forKey: "btBlocklist"), d.object(forKey: "btStyle"), d.object(forKey: "memoryLimitMB"))
        let initial = (settings.btBlocklist, settings.btStyle)
        defer {
            func restore(_ value: Any?, _ key: String) {
                if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
            }
            restore(saved.0, "btBlocklist")
            restore(saved.1, "btStyle")
            restore(saved.2, "memoryLimitMB")
        }

        let keys = settings.settingKeys
        print("settings declared=\(keys.count)")
        check(Set(keys).count == keys.count, "setting keys are unique")
        var received: [String] = [], willChange = 0
        let bag = [settings.$btBlocklist.sink { received.append($0) },
                   settings.objectWillChange.sink { willChange += 1 }]
        check(received == [initial.0], "publisher starts with the current value")

        settings.btBlocklist = "probe-a"
        check(d.string(forKey: "btBlocklist") == "probe-a", "assignment saves")
        check(received.last == "probe-a" && willChange == 1, "assignment notifies once")

        settings.btBlocklist = "probe-a"
        check(willChange == 1 && received.count == 2, "same value does not notify")

        d.set("probe-b", forKey: "btBlocklist")
        settings.reload()
        check(settings.btBlocklist == "probe-b" && received.last == "probe-b", "reload reads a changed value")
        check(willChange == 2, "reload notifies only for what changed")
        settings.reload()
        check(willChange == 2, "reload without changes stays silent")

        let other: AlertStyle = initial.1 == .compact ? .detail : .compact
        d.set(other.rawValue, forKey: "btStyle")
        settings.reload()
        check(settings.btStyle == other, "reload reads a string enum")
        d.set("unknown-style", forKey: "btStyle")
        settings.reload()
        check(settings.btStyle == .compact, "unknown enum value falls back to the default")
        settings.btStyle = .detail
        check(d.string(forKey: "btStyle") == "detail", "enum saves its rawValue")

        d.set(5.0, forKey: "memoryLimitMB")
        settings.reload()
        check(settings.memoryLimitMB == 70, "sanitize clamps on read")
        d.removeObject(forKey: "memoryLimitMB")
        settings.reload()
        check(settings.memoryLimitMB == 70, "missing value uses the default")

        check(settings.isHomeFeatureOn("memo") == !settings.homeDisabled.contains("memo"), "home feature state")

        // 실시간 모니터링: 홈 기능을 끄면 표시할 항목이 남은 쪽으로 (끝나면 되돌린다)
        let savedHome = settings.homeDisabled, savedContent = d.object(forKey: "monitorContent")
        settings.homeDisabled = savedHome.filter { $0 != "usage" && $0 != "resource" }
        settings.monitorContent = .both
        settings.setHomeFeature("usage", on: false)
        check(settings.monitorContent == .resource && settings.effectiveMonitorContent == .resource, "both, AI off → resource")
        settings.setHomeFeature("usage", on: true)
        check(settings.monitorContent == .resource, "turning AI back on doesn't restore both")
        settings.monitorContent = .both
        settings.setHomeFeature("resource", on: false)
        check(settings.monitorContent == .ai && settings.monitorSlots?.left == .aiPrimary, "both, resource off → AI")
        settings.setHomeFeature("usage", on: false)
        check(settings.effectiveMonitorContent == nil && settings.monitorSlots == nil, "both features off → nothing")
        settings.homeDisabled = savedHome
        if let savedContent { d.set(savedContent, forKey: "monitorContent") } else { d.removeObject(forKey: "monitorContent") }
        settings.reload()

        // 순서 정리: 없어진 항목은 빼고, 새 항목은 기본 순서의 바로 앞 항목 뒤에
        let home = AppSettings.defaultHomeOrder, live = AppSettings.defaultPersistentOrder
        check(AppSettings.fixedHomeOrder([]) == home, "home order: empty → default")
        check(AppSettings.fixedHomeOrder(home) == home, "home order: default stays")
        check(AppSettings.fixedHomeOrder(["memo", "usage", "camera", "timer", "calendar", "tray", "chat"])
              == ["memo", "usage", "resource", "camera", "timer", "calendar", "tray", "chat"], "home order: resource goes right after usage")
        check(AppSettings.fixedHomeOrder(["tray", "resource", "gone", "camera"])
              == ["tray", "chat", "resource", "memo", "calendar", "camera", "timer", "usage"], "home order: keeps saved order, drops unknown, adds each new item after its neighbor")
        check(AppSettings.fixedPersistentOrder([]) == live, "live order: empty → default")
        check(AppSettings.fixedPersistentOrder(["media", "aiUsage", "battery"]).first == "call", "live order: call goes first")
        let fixedLive = AppSettings.fixedPersistentOrder(["call", "battery", "aiUsage", "media"])
        check(fixedLive.firstIndex(of: "resource") == fixedLive.firstIndex(of: "aiUsage").map { $0 + 1 }, "live order: resource goes right after AI usage")
        check(Set(fixedLive) == Set(live) && fixedLive.count == live.count, "live order: every item once")

        // 예전 키 이어 받기 (시험용 저장소에서만)
        let suite = "com.dynamicmacnotch.app.probe"
        if let old = UserDefaults(suiteName: suite) {
            old.removePersistentDomain(forName: suite)
            check(AppSettings.savedNotchDisplays(old) == "main", "displays: new install → main")
            old.set(true, forKey: "onboardingDone")
            check(AppSettings.savedNotchDisplays(old) == "builtIn", "displays: old user without a choice → built-in")
            old.set("all", forKey: "displayTarget")
            check(AppSettings.savedNotchDisplays(old) == "all", "displays: old key carries over")
            old.set("main", forKey: "notchDisplays")
            check(AppSettings.savedNotchDisplays(old) == "main", "displays: new key wins")
            check(AppSettings.savedTrayCleanup(old) == 0, "tray cleanup: nothing saved → off")
            old.set(7.0, forKey: "trayCleanupDays")
            check(AppSettings.savedTrayCleanup(old) == 10080, "tray cleanup: days carry over as minutes")
            old.set(30.0, forKey: "trayCleanupMinutes")
            check(AppSettings.savedTrayCleanup(old) == 30, "tray cleanup: new key wins")
            check(SharedNotchState.savedHomeOption(old) == .camera, "last home page: nothing saved → camera")
            old.set(HomeOption.timer.rawValue, forKey: "homeOption")
            check(SharedNotchState.savedHomeOption(old) == .timer, "last home page: old number carries over")
            old.set("memo", forKey: "homeOptionKey")
            check(SharedNotchState.savedHomeOption(old) == .memo, "last home page: name wins")
            old.removePersistentDomain(forName: suite)
        }

        withExtendedLifetime(bag) {}
        print("settings checks=\(checks) failures=\(failures.count)")
        failures.forEach { print("  FAIL", $0) }
        return failures.isEmpty
    }
}
#endif
