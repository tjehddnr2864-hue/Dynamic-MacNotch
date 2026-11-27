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

        // 숫자 범위: 읽을 때와 넣을 때 모두 맞춘다 (끝나면 되돌린다)
        let savedPress = d.object(forKey: "longPressDuration")
        d.set(0.0, forKey: "longPressDuration")
        settings.reload()
        check(settings.longPressDuration == 0.2, "long-press time: clamps a saved value")
        settings.longPressDuration = 5
        check(settings.longPressDuration == 0.8 && d.double(forKey: "longPressDuration") == 0.8, "long-press time: clamps an assigned value")
        if let savedPress { d.set(savedPress, forKey: "longPressDuration") } else { d.removeObject(forKey: "longPressDuration") }
        settings.reload()

        // 네트워크: 무관한 인터페이스의 변화는 건너뛴다
        check(NetworkMonitor.isNoise(key: "State:/Network/Interface/awdl0/IPv6"), "network: awdl is noise")
        check(NetworkMonitor.isNoise(key: "State:/Network/Interface/llw0/IPv6"), "network: llw is noise")
        check(!NetworkMonitor.isNoise(key: "State:/Network/Interface/utun4/IPv4"), "network: a VPN tunnel is not noise")
        check(!NetworkMonitor.isNoise(key: "State:/Network/Interface/en0/IPv4"), "network: Wi-Fi is not noise")
        check(!NetworkMonitor.isNoise(key: "State:/Network/Global/IPv4"), "network: global state is not noise")
        check(!NetworkMonitor.isNoise(key: "State:/Network/Interface"), "network: the interface list is not noise")
        check(!NetworkMonitor.isNoise(interface: "apple0") && NetworkMonitor.isNoise(interface: "ap1"), "network: only whole names match")

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

        // 설정 창 페이지: 아이콘 기호는 바꾸지 않는다 (docs/SETTINGS_REDESIGN_GUIDELINE.md §1.2). 2026-11 개편 전 24개 + 새 페이지
        let frozenSymbols: [String: String] = [
            "general": "gearshape", "displays": "display.2", "priority": "list.number", "home": "square.grid.2x2",
            "network": "wifi", "bluetooth": "airpodspro", "focus": "moon", "call": "phone", "media": "music.note",
            "download": "arrow.down.circle", "airdrop": "tray.and.arrow.down", "screenshot": "camera.viewfinder",
            "recording": "record.circle", "battery": "battery.75percent", "hud": "speaker.wave.2", "lock": "lock",
            "calendar": "calendar", "aiUsage": "gauge.medium", "chat": "bubble.left.and.text.bubble.right", "agent": "terminal",
            "preview": "play.rectangle", "permissions": "hand.raised", "about": "info.circle",
            "notchControls": "hand.tap",
        ]
        for page in SettingsPage.allCases {
            check(frozenSymbols[page.rawValue] == page.symbol, "settings page icon unchanged: \(page.rawValue)")
        }
        let grouped = SettingsGroup.allCases.flatMap(\.pages)
        check(grouped.count == SettingsPage.allCases.count && Set(grouped) == Set(SettingsPage.allCases), "every settings page is in exactly one sidebar group")
        check(SettingsGroup.allCases.allSatisfy { !$0.pages.isEmpty && !$0.title.isEmpty }, "sidebar groups have pages and titles")
        check(SettingsPage(rawValue: "interaction") == nil, "old Interactions page is gone (its pages are in groups)")

        // 값 목록: 예전 목록의 값과 지금 저장된 값이 모두 메뉴에 있어야 빈칸이 안 된다 (가이드라인 §1.3)
        for old in [1.0, 1.5, 2.5, 4.0, 6.0] { check(Choices.duration.contains(old), "duration list keeps old value \(old)") }
        func inList(_ value: Double, _ list: [Double], zero: Bool, _ name: String) {
            check(list.contains(value) || (zero && value == 0), "saved \(name)=\(value) is in its menu")
        }
        inList(settings.transientDuration, Choices.duration, zero: false, "transientDuration")
        inList(settings.hudDuration, Choices.duration, zero: false, "hudDuration")
        inList(settings.netDuration, Choices.duration, zero: true, "netDuration")
        inList(settings.focusDuration, Choices.duration, zero: true, "focusDuration")
        inList(settings.memoryLimitMB, Choices.memoryLimit, zero: false, "memoryLimitMB")
        inList(settings.aiRefreshMinutes, Choices.refresh, zero: false, "aiRefreshMinutes")
        inList(settings.resourceRefreshSeconds, Choices.refresh, zero: false, "resourceRefreshSeconds")
        inList(settings.mediaHideAfterPause, Choices.mediaHide, zero: true, "mediaHideAfterPause")
        inList(settings.screenshotAutoClose, Choices.screenshotClose, zero: false, "screenshotAutoClose")
        inList(settings.calendarAlertMinutes, Choices.calendarAlert, zero: true, "calendarAlertMinutes")
        inList(settings.trayCleanupMinutes, Choices.trayCleanup, zero: true, "trayCleanupMinutes")
        check(Format.seconds(1) == T("1초", "1s") && Format.seconds(1.5) == T("1.5초", "1.5s") && Format.seconds(0.35, digits: 2) == T("0.35초", "0.35s"), "seconds format")
        check(Format.percent(0.355) == "36%" && Format.period(minutes: 10080) == T("7일", "7 days") && Format.period(minutes: 60) == T("1시간", "1 hour"), "percent and period format")

        // 재생 소스: 모든 미디어 ↔ 하나씩 켜기
        check(MediaSource.toggled(.youtube, on: true, in: []) == [.youtube], "sources: turning one on leaves All Media")
        check(MediaSource.toggled(.spotify, on: true, in: [.youtube]) == [.spotify, .youtube], "sources: several at once, in order")
        check(MediaSource.toggled(.youtube, on: false, in: [.youtube]).isEmpty && MediaSource.toggled(.all, on: true, in: [.spotify]).isEmpty, "sources: none or All Media means everything")
        let titles = ["Funny Cat - YouTube", "Side Quest King (Instrumental) - Honkai: Star Rail OST | YouTube Music", "Song B - Example", "YouTube"]
        check(YouTubeSite.fromTitles(titles, title: "Side Quest King (Instrumental)", album: "") == .music && YouTubeSite.fromTitles(titles, title: "funny cat", album: "x") == .video, "youtube: the title that has the song")
        check(YouTubeSite.fromTitles(titles, title: "Song B", album: "") == .video && YouTubeSite.fromTitles(titles, title: "Song B", album: "Album") == .music, "youtube: no match with both kinds open")
        check(YouTubeSite.fromTitles(["YouTube Music"], title: "x", album: "") == .music && YouTubeSite.fromTitles(["x - Example"], title: "x", album: "") == .other && YouTubeSite.fromTitles([], title: "x", album: "") == .other, "youtube: only one kind, or none")
        check(YouTubeSite.kind(ofTitle: "How YouTube works - Example") == .other && YouTubeSite.kind(ofTitle: "a - YouTube Music") == .music, "youtube: only the site name at the end counts")
        check(YouTubeSite.fromApp(bundleID: "app.zen-browser.zen") == nil && YouTubeSite.fromApp(bundleID: "com.github.th-ch.youtube-music") == .music && YouTubeSite.fromApp(bundleID: "com.apple.Music") == .other, "youtube: browsers, music apps and others")

        // 확장 노치에 보일 서비스: 최소 1개, 최대 3개
        let all = AIService.allCases
        check(AIService.shown("", connected: all) == Array(all.prefix(3)), "services: automatic shows the first three")
        check(AIService.shown("", connected: []).isEmpty, "services: none connected")
        check(AIService.shown("gemini,claude", connected: all) == [.claude, .gemini], "services: chosen ones, in the usual order")
        check(AIService.shown("gemini", connected: [.claude]) == [.claude], "services: falls back when the chosen one signs out")
        check(AIService.shown("gemini,unknown,claude", connected: [.claude, .gemini]) == [.claude, .gemini], "services: unknown names are ignored")
        check(AIService.toggled(.claude, on: false, shown: [.claude, .gemini]) == [.gemini], "services: turning one off")
        check(AIService.toggled(.claude, on: false, shown: [.claude]) == [.claude], "services: the last one stays")
        check(AIService.toggled(.chatgpt, on: true, shown: [.claude]) == [.claude, .chatgpt], "services: turning one on")
        check(AIService.refreshTargets(shown: [.claude], pinned: .gemini, connected: all) == [.claude, .gemini], "services: refresh what shows and what's pinned")
        check(AIService.refreshTargets(shown: [.claude], pinned: nil, connected: all) == [.claude], "services: hidden ones aren't read")
        let shorter = (0...4).map { AIService.unusedRowsHeight(shown: $0) }
        check(shorter == [0, 72, 36, 0, 0], "services: one or two rows make the expanded notch shorter: \(shorter)")
        check(SettingsIndex.search("Claude Code").contains { $0.page == .agent } && SettingsIndex.search("Codex").contains { $0.page == .agent }
              && SettingsIndex.search("antigravity").contains { $0.page == .agent }, "search: old name still finds Coding Agents")

        // 설정 검색 (가이드라인 §10.3)
        let index = SettingsIndex.all
        let indexed = Set(index.flatMap(\.keys))
        let missing = keys.filter { !indexed.contains($0) && !SettingsIndex.internalKeys.contains($0) }
        check(missing.isEmpty, "every setting is reachable by search (missing: \(missing.joined(separator: ", ")))")
        check(indexed.isSubset(of: Set(keys)), "search index names only real settings")
        check(Set(index.map(\.id)).count == index.count, "search ids are unique")
        check(SettingsPage.allCases.allSatisfy { p in index.contains { $0.isPage && $0.page == p } }, "every page is in the search index")
        check(index.count > 120, "search index has rows, not just pages (\(index.count))")
        for e in index {
            check(SettingsIndex.search(e.title.ko).contains { $0.id == e.id }, "found by Korean name: \(e.id)")
            check(SettingsIndex.search(e.title.en).contains { $0.id == e.id }, "found by English name: \(e.id)")
        }
        func first(_ q: String) -> String? { SettingsIndex.search(q).first?.id }
        let volume = SettingsIndex.search("음량").first { $0.page == .hud }?.id
        check(volume != nil && ["volume", "볼륨", "Volume"].allSatisfy { q in SettingsIndex.search(q).contains { $0.id == volume } }, "synonyms: 볼륨·volume find 음량")
        check(SettingsIndex.search("음량".decomposedStringWithCanonicalMapping).contains { $0.id == volume }, "decomposed Hangul input still matches")
        check(SettingsIndex.search("ㅇㄹ").contains { $0.id == volume }, "initial consonants: ㅇㄹ finds 음량")
        check(SettingsIndex.search("").isEmpty && SettingsIndex.search("   ").isEmpty, "empty query finds nothing")
        check(SettingsIndex.search("zzqqxx").isEmpty, "nonsense finds nothing")
        check(first("투명도")?.hasPrefix("general.") == true || first("투명도")?.hasPrefix("hud.") == true, "name match ranks first")
        check(SettingsIndex.initials("음량 HUD") == "ㅇㄹHUD", "initials keep non-Hangul")
        let start = Date()
        for q in ["a", "알", "표시", "wi", "ㅂ", "volume"] { _ = SettingsIndex.search(q) }
        let perQuery = Date().timeIntervalSince(start) / 6
        print("search: \(index.count) entries, \(String(format: "%.2f", perQuery * 1000)) ms per query")
        check(perQuery < 0.02, "search answers within 20 ms per keystroke")

        withExtendedLifetime(bag) {}
        print("settings checks=\(checks) failures=\(failures.count)")
        failures.forEach { print("  FAIL", $0) }
        return failures.isEmpty
    }
}
#endif
