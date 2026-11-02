import SwiftUI
import Combine
import IOKit.ps

/// 배터리 이벤트 감지 (가이드라인 5.6): 충전기 연결, 부족 경고, 완충.
final class BatteryMonitor: ObservableObject {
    struct Snapshot: Equatable {
        var percent: Int
        var isCharging: Bool
        var onAC: Bool
        var isCharged: Bool
        var minutesToFull: Int?
    }

    @Published private(set) var snapshot: Snapshot?

    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private var source: CFRunLoopSource?
    private var lastACChange = Date.distantPast
    private var lowArmed = true
    private var cancellables = Set<AnyCancellable>()

    init(center: ActivityCenter) {
        self.center = center
    }

    func start() {
        snapshot = Self.read()
        applyChargingPin()
        settings.$batteryChargingPinned
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyChargingPin() }
            .store(in: &cancellables)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue() else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    static func read() -> Snapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  desc["Type"] as? String == "InternalBattery" else { continue }
            let current = desc["Current Capacity"] as? Int ?? 0
            let max = desc["Max Capacity"] as? Int ?? 100
            let toFull = desc["Time to Full Charge"] as? Int ?? -1
            return Snapshot(
                percent: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current,
                isCharging: desc["Is Charging"] as? Bool ?? false,
                onAC: desc["Power Source State"] as? String == "AC Power",
                isCharged: desc["Is Charged"] as? Bool ?? false,
                minutesToFull: toFull > 0 ? toFull : nil
            )
        }
        return nil
    }

    static func symbol(for percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func refresh() {
        guard let new = Self.read() else { return }
        let old = snapshot
        snapshot = new
        applyChargingPin()
        guard let old else { return }

        // 충전기 연결 (빠르게 뺐다 꽂는 경우 2초 디바운스)
        if new.onAC != old.onAC {
            let quick = Date().timeIntervalSince(lastACChange) < 2
            lastACChange = Date()
            if new.onAC, !quick, settings.batteryChargerAlert {
                postCharger(new)
            }
        }

        // 부족 경고: 기준값을 아래로 지날 때 1회. 충전기를 꽂거나 기준 +5%를 넘어야 다시 무장.
        let threshold = Int(settings.batteryLowThreshold)
        if new.onAC || new.percent >= threshold + 5 { lowArmed = true }
        if lowArmed, !new.onAC, new.percent <= threshold, settings.batteryLowAlert {
            lowArmed = false
            postLow(new)
        }

        // 완충: Is Charged가 켜지거나, 충전 한도(최적화 충전 등)에 도달해 충전이 멈춤
        let reachedLimit = new.onAC && old.isCharging && !new.isCharging && new.percent >= 80
        if ((new.isCharged && !old.isCharged) || reachedLimit), settings.batteryFullAlert {
            postFull(new)
        }
    }

    // MARK: - 충전 중 상시 표시

    /// 실제로 충전 중일 때만: 어댑터 연결 + 충전 중 + 완충 아님.
    /// 완충됐거나 충전 한도·최적화 충전으로 멈춰 어댑터로만 동작(바이패스)하는 동안은 띄우지 않는다.
    static func isActuallyCharging(_ s: Snapshot) -> Bool { s.onAC && s.isCharging && !s.isCharged }

    private func applyChargingPin() {
        guard settings.batteryChargingPinned, let s = snapshot, Self.isActuallyCharging(s) else {
            center.removePersistent(.battery)
            return
        }
        center.setPersistent(Self.chargingActivity(s))
    }

    /// 왼쪽: 배터리 아이콘 위에 % / 오른쪽: 완충까지 남은 시간 (macOS가 계산한 값, 계산 중이면 –)
    static func chargingActivity(_ s: Snapshot) -> NotchActivity {
        let level = Double(s.percent) / 100
        let remaining = s.minutesToFull.map { String(format: "%d:%02d", $0 / 60, $0 % 60) } ?? "–"
        let subtitle = s.minutesToFull.map { T("완충까지 \($0 / 60)시간 \($0 % 60)분", "\($0 / 60)h \($0 % 60)m until full") }
            ?? T("완충까지 남은 시간 계산 중", "Estimating time to full")
        return NotchActivity(
            kind: .battery, priority: ActivityPriority.pinned, symbol: "bolt.fill", tint: .green,
            value: .labeledText(label: T("완충까지", "to full"), text: remaining),
            title: T("충전 중 \(s.percent)%", "Charging \(s.percent)%"), subtitle: subtitle,
            detailValue: .percent(level), wing: NotchActivity.compactWing,
            leadingValue: .batteryLevel(level))
    }

    // MARK: - 액티비티

    func postCharger(_ s: Snapshot, style: AlertStyle? = nil) {
        var subtitle = T("충전 중", "Charging")
        if let m = s.minutesToFull { subtitle = T("완충까지 \(m / 60)시간 \(m % 60)분", "\(m / 60)h \(m % 60)m until full") }
        center.post(NotchActivity(
            kind: .battery,
            presentation: (style ?? settings.batteryStyle) == .detail ? .detail : .compact,
            symbol: "bolt.fill",
            tint: .green,
            value: .text("\(s.percent)%"),
            title: T("충전기 연결됨", "Charger Connected"),
            subtitle: subtitle,
            detailValue: .percent(Double(s.percent) / 100),
            wing: 56,
            battery: BatteryGlyphInfo(level: Double(s.percent) / 100, charging: true)
        ))
    }

    func postLow(_ s: Snapshot, style: AlertStyle? = nil) {
        center.post(NotchActivity(
            kind: .battery,
            priority: ActivityPriority.batteryLow,
            presentation: (style ?? settings.batteryStyle) == .detail ? .detail : .compact,
            duration: max(4, settings.transientDuration),
            symbol: Self.symbol(for: s.percent),
            tint: .red,
            value: .text("\(s.percent)%"),
            title: T("배터리 부족", "Low Battery"),
            subtitle: T("충전기를 연결하세요", "Connect a charger"),
            detailValue: .percent(Double(s.percent) / 100),
            wing: 56,
            battery: BatteryGlyphInfo(level: Double(s.percent) / 100, charging: false)
        ))
    }

    func postFull(_ s: Snapshot, style: AlertStyle? = nil) {
        center.post(NotchActivity(
            kind: .battery,
            presentation: (style ?? settings.batteryStyle) == .detail ? .detail : .compact,
            symbol: "battery.100percent.bolt",
            tint: .green,
            value: .text(T("완충", "Full")),
            title: T("충전 완료", "Fully Charged"),
            subtitle: T("배터리 \(s.percent)%", "Battery \(s.percent)%"),
            detailValue: .percent(Double(s.percent) / 100),
            wing: 56,
            battery: BatteryGlyphInfo(level: 1, charging: false)
        ))
    }
}
