import Combine
import SwiftUI

/// 실시간 모니터링의 상시 표시 활동을 만든다 (미리보기도 같은 함수를 쓴다).
/// 자원 값은 활동에 넣지 않고 `.metric`으로 칸만 정한다 (값은 ResourceSampler가 따로 갱신).
enum MonitorActivity {
    /// AI 사용량. 칸마다 설정에서 고른 한도나 서비스 기호 (`ServiceUsage.sides`).
    /// 자동: 한도가 둘 이상이면 왼쪽 가장 짧은 한도, 오른쪽 가장 긴 한도. 하나면(무료 30일, 주간 한도만 있는 요금제 등) 왼쪽 서비스 기호.
    static func ai(service: AIService, usage: ServiceUsage?, ring: Bool,
                   sides choice: (left: String?, right: String?) = (nil, nil)) -> NotchActivity {
        let left: ActivityValue, right: ActivityValue
        if let s = usage?.sides(left: choice.left, right: choice.right) {
            left = value(of: s.left, service: service, ring: ring)
            right = value(of: s.right, service: service, ring: ring)
        } else {
            left = value(for: .aiPrimary, usage: usage, ring: ring)
            right = value(for: .aiSecondary, usage: usage, ring: ring)
        }
        return NotchActivity(kind: .aiUsage, priority: ActivityPriority.pinned, symbol: "gauge.medium", tint: service.tint,
                             value: right, title: T("\(service.name) 사용량", "\(service.name) Usage"),
                             subtitle: summary(usage), wing: NotchActivity.compactWing, leadingValue: left)
    }

    /// 자원 사용량 (칸 두 개 모두 자원)
    static func resource(slots: (left: MonitorMetric, right: MonitorMetric), ring: Bool) -> NotchActivity {
        NotchActivity(kind: .resource, priority: ActivityPriority.pinned, symbol: "cpu", tint: resourceTint,
                      value: value(for: slots.right, usage: nil, ring: ring),
                      title: T("자원 사용량", "Resource Usage"), wing: NotchActivity.compactWing,
                      leadingValue: value(for: slots.left, usage: nil, ring: ring))
    }

    /// AI 및 자원 사용량 (칸마다 AI 또는 자원). AI ①·②는 AI 사용량의 왼쪽·오른쪽 선택을 따른다 (자동이면 짧은 한도·긴 한도).
    static func combined(slots: (left: MonitorMetric, right: MonitorMetric), service: AIService?, usage: ServiceUsage?, ring: Bool,
                         sides choice: (left: String?, right: String?) = (nil, nil)) -> NotchActivity {
        func cell(_ metric: MonitorMetric) -> ActivityValue {
            let picked = metric == .aiPrimary ? choice.left : metric == .aiSecondary ? choice.right : nil
            if picked != nil, let service, let s = usage?.sides(left: choice.left, right: choice.right) {
                return value(of: metric == .aiPrimary ? s.left : s.right, service: service, ring: ring)
            }
            return value(for: metric, usage: usage, ring: ring)
        }
        return NotchActivity(kind: .monitor, priority: ActivityPriority.pinned, symbol: "gauge.medium", tint: service?.tint ?? resourceTint,
                             value: cell(slots.right),
                             title: T("AI 및 자원 사용량", "AI & Resource Usage"), subtitle: summary(usage),
                             wing: NotchActivity.compactWing, leadingValue: cell(slots.left))
    }

    static func value(of side: AISide, service: AIService, ring: Bool) -> ActivityValue {
        switch side {
        case .mark: return .serviceMark(service)
        case .window(let w): return .usage(label: w.shortLabel, percent: w.percent, ring: ring)
        }
    }

    static let resourceTint = Color.mint

    /// 칸 하나의 값
    static func value(for metric: MonitorMetric, usage: ServiceUsage?, ring: Bool) -> ActivityValue {
        let windows = usage?.windows ?? []
        switch metric {
        case .aiPrimary:
            guard let w = windows.first else { return .usage(label: "5h", percent: nil, ring: ring) }
            return .usage(label: w.shortLabel, percent: w.percent, ring: ring)
        case .aiSecondary:
            if windows.count > 1, let w = windows.last { return .usage(label: w.shortLabel, percent: w.percent, ring: ring) }
            // 한도가 하나뿐이면 둘째 칸에는 그 한도가 초기화될 때까지 남은 시간
            if let only = windows.first { return .labeledText(label: T("초기화", "reset"), text: only.resetsAt.map(UsageGlyph.shortRemaining) ?? "–") }
            return .usage(label: "wk", percent: nil, ring: ring)
        case .net:
            return .metric(.net, ring: false)   // 속도에는 원형이 의미가 없다
        case .cpu, .gpu, .mem:
            return .metric(metric, ring: ring)
        }
    }

    private static func summary(_ usage: ServiceUsage?) -> String {
        let text = (usage?.windows ?? []).map { "\($0.label) \(Int($0.percent.rounded()))%" }.joined(separator: " · ")
        return text.isEmpty ? T("불러오는 중…", "Loading…") : text
    }
}

/// 설정에 따라 실시간 모니터링 상시 표시를 게시한다. 측정할 지표는 NotchHub가 디스플레이마다 실제로 보이는 칸으로 정한다.
final class MonitorCoordinator {
    private let center: ActivityCenter
    private let usage: UsageStore
    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()

    init(center: ActivityCenter, usage: UsageStore) {
        self.center = center
        self.usage = usage
    }

    func start() {
        settings.objectWillChange.map { _ in () }
            .merge(with: usage.objectWillChange.map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &cancellables)
        update()
    }

    private func update() {
        let needed = settings.monitorKindsNeeded
        let ring = settings.aiUsageStyle == .ring
        let service = usage.pinnedService

        if needed.contains(.aiUsage), let service {
            center.setPersistent(MonitorActivity.ai(service: service, usage: usage.usage[service], ring: ring, sides: settings.aiSides(service)))
        } else {
            center.removePersistent(.aiUsage)
        }
        if needed.contains(.resource) {
            center.setPersistent(MonitorActivity.resource(slots: settings.resourceSlots, ring: ring))
        } else {
            center.removePersistent(.resource)
        }
        if needed.contains(.monitor) {
            center.setPersistent(MonitorActivity.combined(slots: settings.bothSlots, service: service, usage: service.flatMap { usage.usage[$0] }, ring: ring,
                                                          sides: service.map(settings.aiSides) ?? (nil, nil)))
        } else {
            center.removePersistent(.monitor)
        }
    }
}
