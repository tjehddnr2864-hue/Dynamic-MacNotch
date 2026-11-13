import Foundation

// 실시간 모니터링(AI 사용량 + 자원 사용량)의 설정 해석. 화면과 저장소에 의존하지 않는 순수 계산이다.
// 규칙은 docs/RESOURCE_GUIDELINE.md §3, 시험은 `--monitor-probe`.

/// 노치에 실시간으로 보일 것. 홈 기능으로 켠 것만 고를 수 있다.
enum MonitorContent: String, CaseIterable, Identifiable {
    case ai, resource, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ai: return T("AI 사용량", "AI Usage")
        case .resource: return T("자원 사용량", "Resource Usage")
        case .both: return T("둘 다", "Both")
        }
    }
    var includesAI: Bool { self != .resource }
    var includesResource: Bool { self != .ai }
}

/// 노치를 꾹 눌렀을 때 보일 확장 화면
enum MonitorExpand: String, CaseIterable, Identifiable {
    case follow, ai, resource, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .follow: return T("노치에 보이는 항목을 따름", "Same as shown")
        case .ai: return T("AI 사용량", "AI Usage")
        case .resource: return T("자원 사용량", "Resource Usage")
        case .both: return T("둘 다 (점으로 넘김)", "Both (swipe between)")
        }
    }
}

/// 노치 양옆 칸 하나에 보일 항목
enum MonitorMetric: String, CaseIterable, Identifiable {
    /// AI 한도 중 기간이 가장 짧은 것 (보통 5시간, 없으면 주간 같은 유일한 한도)
    case aiPrimary
    /// AI 한도 중 그다음 (보통 주간)
    case aiSecondary
    case cpu, gpu, mem, net

    var id: String { rawValue }
    var isAI: Bool { self == .aiPrimary || self == .aiSecondary }

    static let resourceMetrics: [MonitorMetric] = [.cpu, .gpu, .mem, .net]

    /// 설정 메뉴의 이름
    var label: String {
        switch self {
        case .aiPrimary: return T("AI 사용량 ① (기본 5시간)", "AI usage ① (5-hour by default)")
        case .aiSecondary: return T("AI 사용량 ② (기본 주간)", "AI usage ② (weekly by default)")
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .mem: return T("메모리", "Memory")
        case .net: return T("네트워크", "Network")
        }
    }
}

/// 홈 기능 중 실시간 모니터링에 속한 둘
enum MonitorFeature {
    case ai, resource
}

enum MonitorLayout {
    /// 홈 기능으로 켜진 것으로 제한한 표시할 항목. 둘 다 꺼져 있으면 nil(보일 것이 없음).
    static func effectiveContent(_ saved: MonitorContent, aiOn: Bool, resourceOn: Bool) -> MonitorContent? {
        switch (aiOn, resourceOn) {
        case (true, true): return saved
        case (true, false): return .ai
        case (false, true): return .resource
        case (false, false): return nil
        }
    }

    /// 설정 화면에서 고를 수 있는 표시할 항목
    static func availableContents(aiOn: Bool, resourceOn: Bool) -> [MonitorContent] {
        MonitorContent.allCases.filter { ($0.includesAI ? aiOn : true) && ($0.includesResource ? resourceOn : true) }
    }

    /// 홈 기능 하나를 끌 때 표시할 항목을 어떻게 바꿀지. 남은 기능이 없으면 그대로 둔다.
    static func contentAfterTurningOff(_ feature: MonitorFeature, current: MonitorContent, otherOn: Bool) -> MonitorContent {
        guard otherOn else { return current }
        switch feature {
        case .ai: return current.includesAI ? .resource : current
        case .resource: return current.includesResource ? .ai : current
        }
    }

    /// 칸에 고를 수 있는 항목
    static func choices(for content: MonitorContent) -> [MonitorMetric] {
        switch content {
        case .ai: return [.aiPrimary, .aiSecondary]
        case .resource: return MonitorMetric.resourceMetrics
        case .both: return MonitorMetric.allCases
        }
    }

    static func defaults(for content: MonitorContent) -> (left: MonitorMetric, right: MonitorMetric) {
        switch content {
        case .ai: return (.aiPrimary, .aiSecondary)
        case .resource: return (.cpu, .mem)
        case .both: return (.aiPrimary, .cpu)
        }
    }

    /// 저장된 칸을 그 모드에서 쓸 수 있는 값으로 푼다. AI 사용량은 칸이 고정이다.
    /// 쓸 수 없는 값은 기본값으로, 양쪽이 같으면 오른쪽을 다른 값으로 바꾼다 (저장값은 건드리지 않는다).
    static func slots(_ content: MonitorContent, left: MonitorMetric, right: MonitorMetric) -> (left: MonitorMetric, right: MonitorMetric) {
        let fallback = defaults(for: content)
        guard content != .ai else { return fallback }
        let options = choices(for: content)
        let l = options.contains(left) ? left : fallback.left
        var r = options.contains(right) ? right : fallback.right
        if r == l {
            r = [fallback.right, fallback.left].first { $0 != l } ?? options.first { $0 != l } ?? r
        }
        return (l, r)
    }

    /// 꾹 눌렀을 때 보일 확장 화면. 꺼진 기능을 고른 값이면 표시할 항목을 따른다.
    static func expandContent(_ saved: MonitorExpand, content: MonitorContent?, aiOn: Bool, resourceOn: Bool) -> MonitorContent? {
        let wanted: MonitorContent?
        switch saved {
        case .follow: wanted = content
        case .ai: wanted = .ai
        case .resource: wanted = .resource
        case .both: wanted = .both
        }
        guard let wanted, availableContents(aiOn: aiOn, resourceOn: resourceOn).contains(wanted) else { return content }
        return wanted
    }

    /// 설정 화면에서 고를 수 있는 확장 화면
    static func availableExpands(aiOn: Bool, resourceOn: Bool) -> [MonitorExpand] {
        let contents = availableContents(aiOn: aiOn, resourceOn: resourceOn)
        return MonitorExpand.allCases.filter { option in
            switch option {
            case .follow: return !contents.isEmpty
            case .ai: return contents.contains(.ai)
            case .resource: return contents.contains(.resource)
            case .both: return contents.contains(.both)
            }
        }
    }
}

#if DEV
/// 개발용: `--monitor-probe` 실시간 모니터링 설정 해석을 확인한다.
enum MonitorProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--monitor-probe") else { return }
        var checks = 0, failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures.append(what) }
        }
        let bools = [true, false]

        // 표시할 항목: 켜진 기능으로만 제한
        for saved in MonitorContent.allCases {
            for ai in bools {
                for res in bools {
                    let e = MonitorLayout.effectiveContent(saved, aiOn: ai, resourceOn: res)
                    let available = MonitorLayout.availableContents(aiOn: ai, resourceOn: res)
                    if let e {
                        check(available.contains(e), "effective \(saved) ai=\(ai) res=\(res) is available")
                        check(!e.includesAI || ai, "effective without AI \(saved)")
                        check(!e.includesResource || res, "effective without resource \(saved)")
                    } else {
                        check(!ai && !res, "nil only when both off")
                    }
                    if ai && res { check(e == saved, "both on keeps the saved value \(saved)") }
                }
            }
        }
        check(MonitorLayout.availableContents(aiOn: true, resourceOn: true) == [.ai, .resource, .both], "all three when both on")
        check(MonitorLayout.availableContents(aiOn: true, resourceOn: false) == [.ai], "AI only")
        check(MonitorLayout.availableContents(aiOn: false, resourceOn: true) == [.resource], "resource only")
        check(MonitorLayout.availableContents(aiOn: false, resourceOn: false).isEmpty, "nothing")

        // 홈 기능 연동: 둘 다인데 한쪽을 끄면 남은 쪽
        check(MonitorLayout.contentAfterTurningOff(.ai, current: .both, otherOn: true) == .resource, "both, AI off → resource")
        check(MonitorLayout.contentAfterTurningOff(.resource, current: .both, otherOn: true) == .ai, "both, resource off → AI")
        check(MonitorLayout.contentAfterTurningOff(.ai, current: .ai, otherOn: true) == .resource, "AI, AI off → resource")
        check(MonitorLayout.contentAfterTurningOff(.ai, current: .resource, otherOn: true) == .resource, "resource, AI off → unchanged")
        check(MonitorLayout.contentAfterTurningOff(.resource, current: .ai, otherOn: true) == .ai, "AI, resource off → unchanged")
        check(MonitorLayout.contentAfterTurningOff(.ai, current: .both, otherOn: false) == .both, "nothing left → unchanged")

        // 칸: 모든 조합이 그 모드에서 가능한 서로 다른 두 값으로 풀린다
        for content in MonitorContent.allCases {
            for l in MonitorMetric.allCases {
                for r in MonitorMetric.allCases {
                    let s = MonitorLayout.slots(content, left: l, right: r)
                    let options = MonitorLayout.choices(for: content)
                    check(options.contains(s.left) && options.contains(s.right), "slots in range \(content) \(l) \(r)")
                    check(s.left != s.right, "slots differ \(content) \(l) \(r)")
                    if content != .ai, options.contains(l) { check(s.left == l, "valid left kept \(content) \(l) \(r)") }
                    if content != .ai, options.contains(l), options.contains(r), l != r { check(s.right == r, "valid pair kept \(content) \(l) \(r)") }
                }
            }
        }
        let ai = MonitorLayout.slots(.ai, left: .cpu, right: .net)
        check(ai.left == .aiPrimary && ai.right == .aiSecondary, "AI slots are fixed")
        let res = MonitorLayout.slots(.resource, left: .aiPrimary, right: .gpu)
        check(res.left == .cpu && res.right == .gpu, "AI item in resource falls back")
        let same = MonitorLayout.slots(.resource, left: .mem, right: .mem)
        check(same.left == .mem && same.right == .cpu, "same item: right moves to another")

        // 확장 화면
        check(MonitorLayout.expandContent(.follow, content: .both, aiOn: true, resourceOn: true) == .both, "follow")
        check(MonitorLayout.expandContent(.resource, content: .ai, aiOn: true, resourceOn: true) == .resource, "explicit resource")
        check(MonitorLayout.expandContent(.resource, content: .ai, aiOn: true, resourceOn: false) == .ai, "resource off → follow")
        check(MonitorLayout.expandContent(.both, content: .resource, aiOn: false, resourceOn: true) == .resource, "both unavailable → follow")
        check(MonitorLayout.expandContent(.follow, content: nil, aiOn: false, resourceOn: false) == nil, "nothing on")
        check(MonitorLayout.availableExpands(aiOn: true, resourceOn: false) == [.follow, .ai], "expand options, AI only")
        check(MonitorLayout.availableExpands(aiOn: false, resourceOn: false).isEmpty, "expand options, nothing")

        // 활동 조립: 한도 수에 따라 칸이 바뀐다
        let five = UsageWindow(percent: 42, resetsAt: nil, seconds: UsageWindow.fiveHours)
        let week = UsageWindow(percent: 76, resetsAt: Date().addingTimeInterval(86400), seconds: UsageWindow.week)
        let two = ServiceUsage(windows: [week, five], fetched: Date())
        let weekOnly = ServiceUsage(windows: [week], fetched: Date())
        var a = MonitorActivity.ai(service: .claude, usage: two, ring: false)
        check(a.leadingValue == .usage(label: "5h", percent: 42, ring: false) && a.value == .usage(label: "wk", percent: 76, ring: false), "two limits: 5h left, weekly right")
        a = MonitorActivity.ai(service: .claude, usage: weekOnly, ring: false)
        check(a.leadingValue == .serviceMark(.claude) && a.value == .usage(label: "wk", percent: 76, ring: false), "weekly only: mark left, weekly right")
        a = MonitorActivity.ai(service: .gemini, usage: nil, ring: true)
        check(a.leadingValue == .usage(label: "5h", percent: nil, ring: true) && a.value == .usage(label: "wk", percent: nil, ring: true), "not loaded yet")
        check(MonitorActivity.value(for: .aiPrimary, usage: weekOnly, ring: false) == .usage(label: "wk", percent: 76, ring: false), "primary = shortest limit")
        if case .labeledText = MonitorActivity.value(for: .aiSecondary, usage: weekOnly, ring: false) { checks += 1 } else { check(false, "secondary with one limit = reset time") }
        check(MonitorActivity.value(for: .net, usage: nil, ring: true) == .metric(.net, ring: false), "network never ring")
        let r = MonitorActivity.resource(slots: (.gpu, .mem), ring: true)
        check(r.kind == .resource && r.leadingValue == .metric(.gpu, ring: true) && r.value == .metric(.mem, ring: true), "resource slots")
        let m = MonitorActivity.combined(slots: (.aiPrimary, .cpu), service: .chatgpt, usage: two, ring: false)
        check(m.kind == .monitor && m.leadingValue == .usage(label: "5h", percent: 42, ring: false) && m.value == .metric(.cpu, ring: false), "combined slots")
        var again = MonitorActivity.resource(slots: (.cpu, .mem), ring: false)
        let first = MonitorActivity.resource(slots: (.cpu, .mem), ring: false)
        again.id = first.id   // 게시할 때처럼 번호를 맞추면 내용이 같다 → 다시 그리지 않는다
        check(again == first, "same settings, same activity (no repost)")

        // 우선순위: 새 항목은 기본 순서에서 앞 항목 바로 뒤에 들어간다 (기존 사용자도 자원 사용량이 AI 사용량 아래)
        let saved = ["call", "timer", "recording", "download", "airdrop", "media", "hotspot", "battery", "aiUsage", "vpn", "focusPinned", "calendar"]
        let fixed = AppSettings.fixedPersistentOrder(saved)
        check(fixed.firstIndex(of: "resource") == fixed.firstIndex(of: "aiUsage").map { $0 + 1 }, "resource right after aiUsage")
        check(fixed.filter { $0 != "resource" } == saved, "user order kept")

        // Claude 응답: 5시간 한도가 없거나 비어 있어도 주간 한도를 읽는다
        func claude(_ json: String) -> ServiceUsage? { UsageParser.claude(Data(json.utf8)) }
        check(claude(#"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":30,"resets_at":null}}"#)?.windows.count == 2, "both limits")
        check(claude(#"{"five_hour":null,"seven_day":{"utilization":30,"resets_at":null}}"#)?.windows.map(\.seconds) == [UsageWindow.week], "five_hour null")
        check(claude(#"{"seven_day":{"utilization":30}}"#)?.windows.map(\.seconds) == [UsageWindow.week], "five_hour missing")
        check(claude(#"{"five_hour":{"utilization":null},"seven_day":{"utilization":30}}"#)?.windows.map(\.seconds) == [UsageWindow.week], "five_hour without a value")

        // Claude Max: 5시간·주간·모델별 주간(Fable). 자동은 5시간·주간, 모델 한도는 고를 때만
        let max = claude(#"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":30,"resets_at":null},"seven_day_fable":{"utilization":55,"resets_at":null},"seven_day_opus":null,"seven_day_oauth_apps":{"utilization":3}}"#)
        check(max?.windows.map(\.id) == ["5h", "168h", "168h:fable"], "max: 5h, weekly, Fable weekly (oauth apps and null skipped)")
        check(max?.windows.last?.label == T("Fable 주간", "Fable Weekly") && max?.windows.last?.shortLabel == "Fable", "Fable labels")
        if let max {
            var sd = max.sides(left: nil, right: nil)
            check(sd?.left == .window(max.windows[0]) && sd?.right == .window(max.windows[1]), "max auto: 5h | weekly")
            sd = max.sides(left: "168h:fable", right: nil)
            check(sd?.left == .window(max.windows[2]) && sd?.right == .window(max.windows[1]), "max: Fable | auto weekly")
            sd = max.sides(left: nil, right: "5h")
            check(sd?.right == .window(max.windows[0]) && sd?.left != sd?.right, "auto side never repeats the chosen one")
            sd = max.sides(left: "mark", right: "168h:fable")
            check(sd?.left == .mark && sd?.right == .window(max.windows[2]), "max: mark | Fable")
            let act = MonitorActivity.ai(service: .claude, usage: max, ring: false, sides: ("168h", "168h:fable"))
            check(act.leadingValue == .usage(label: "wk", percent: 30, ring: false) && act.value == .usage(label: "Fable", percent: 55, ring: false), "activity follows the choice")
            check(max.sideChoices.map(\.id) == ["mark", "5h", "168h", "168h:fable"], "choices: mark + every limit")
        }
        // Claude 새 응답(limits 목록): 세션·주간·Fable. 예전 키는 null이어도 목록을 쓴다
        let pro = claude(#"{"five_hour":{"utilization":17,"resets_at":"2026-11-13T09:10:00.112966+00:00"},"seven_day_opus":null,"limits":[{"kind":"session","group":"session","percent":17,"resets_at":"2026-11-13T09:10:00.112966+00:00","scope":null},{"kind":"weekly_all","group":"weekly","percent":24,"resets_at":"2026-11-15T22:59:59.112986+00:00","scope":null},{"kind":"weekly_scoped","group":"weekly","percent":6,"resets_at":"2026-11-15T23:00:00.113304+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},{"kind":"weekly_scoped","group":"weekly","percent":1,"scope":{"model":null,"surface":null}}]}"#)
        check(pro?.windows.map(\.id) == ["5h", "168h", "168h:fable"], "limits list: session, weekly, Fable (unknown scope skipped)")
        check(pro?.windows.map(\.percent) == [17, 24, 6] && pro?.windows[2].resetsAt != nil, "limits list: values and reset time")
        let ultraList = claude(#"{"limits":[{"kind":"weekly_all","group":"weekly","percent":20},{"kind":"weekly_scoped","group":"weekly","percent":40,"scope":{"model":{"display_name":"Fable"}}}]}"#)
        check(ultraList?.windows.map(\.id) == ["168h", "168h:fable"] && ultraList?.sides(left: nil, right: nil)?.left == .mark, "limits list without a session (Ultra)")
        // Claude Ultra: 5시간 없음. 자동은 기호 | 주간, 5시간을 골라 뒀으면 그 칸은 자동으로 돌아간다
        let ultra = claude(#"{"five_hour":null,"seven_day":{"utilization":20,"resets_at":null},"seven_day_fable":{"utilization":40,"resets_at":null}}"#)
        check(ultra?.windows.map(\.id) == ["168h", "168h:fable"], "ultra: weekly and Fable only")
        if let ultra {
            var sd = ultra.sides(left: nil, right: nil)
            check(sd?.left == .mark && sd?.right == .window(ultra.windows[0]), "ultra auto: mark | weekly")
            sd = ultra.sides(left: "5h", right: "168h:fable")
            check(sd?.left == .mark && sd?.right == .window(ultra.windows[1]), "missing 5h falls back to auto")
            sd = ultra.sides(left: "168h", right: "168h:fable")
            check(sd?.left == .window(ultra.windows[0]) && sd?.right == .window(ultra.windows[1]), "ultra: weekly | Fable")
        }
        // 설정: 반대쪽과 같은 것을 고르면 반대쪽은 자동으로
        let savedSides = UserDefaults.standard.object(forKey: "aiUsageSides")
        AppSettings.shared.setAISide("168h", service: .claude, left: false)
        AppSettings.shared.setAISide("168h", service: .claude, left: true)
        check(AppSettings.shared.aiSides(.claude) == ("168h", nil), "same choice moves, other side goes automatic")
        if let savedSides { UserDefaults.standard.set(savedSides, forKey: "aiUsageSides") } else { UserDefaults.standard.removeObject(forKey: "aiUsageSides") }
        AppSettings.shared.reload()
        // ChatGPT: 전체 한도(rate_limit)와 기능별 한도가 같은 기간이어도 서로 덮지 않는다 (2026-12 통합 대비)
        func gpt(_ json: String) -> ServiceUsage? { UsageParser.chatgpt(Data(json.utf8)) }
        let merged = gpt(#"{"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":60},"secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_after_seconds":60}},"code_review_rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":604800}}}"#)
        check(merged?.windows.map(\.id) == ["5h", "168h", "168h:code review"], "chatgpt: overall + code review weekly kept apart")
        check(merged?.windows.first(where: { $0.id == "168h" })?.percent == 40, "chatgpt: overall weekly not overwritten")
        let named = gpt(#"{"rate_limit":{"primary_window":{"used_percent":7,"limit_window_seconds":604800}},"additional_rate_limits":[{"limit_name":"Codex","rate_limit":{"primary_window":{"used_percent":9,"limit_window_seconds":604800}}}]}"#)
        check(named?.windows.map(\.id) == ["168h", "168h:codex"], "chatgpt: named limit in a list")
        let free = gpt(#"{"rate_limit":{"primary_window":{"used_percent":7,"limit_window_seconds":2592000}}}"#)
        check(free?.windows.count == 1 && free?.sides(left: nil, right: nil)?.left == .mark, "chatgpt free: mark | 30-day")
        // 예전 캐시(이름 없음)도 읽힌다
        let old = try? JSONDecoder().decode(UsageWindow.self, from: Data(#"{"percent":10,"seconds":18000}"#.utf8))
        check(old?.id == "5h" && old?.name == nil, "old cache decodes")

        print("monitor checks=\(checks) failures=\(failures.count)")
        failures.prefix(10).forEach { print("  FAIL", $0) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
#endif
