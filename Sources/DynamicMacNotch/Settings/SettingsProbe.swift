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

        print("settings declared=\(settings.settingCount)")
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

        withExtendedLifetime(bag) {}
        print("settings checks=\(checks) failures=\(failures.count)")
        failures.forEach { print("  FAIL", $0) }
        return failures.isEmpty
    }
}
#endif
