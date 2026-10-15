import SwiftUI
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

    init(center: ActivityCenter) {
        self.center = center
    }

    func start() {
        snapshot = Self.read()
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

    // MARK: - 액티비티

    func postCharger(_ s: Snapshot) {
        var subtitle = T("충전 중", "Charging")
        if let m = s.minutesToFull { subtitle = T("완충까지 \(m / 60)시간 \(m % 60)분", "\(m / 60)h \(m % 60)m until full") }
        center.post(NotchActivity(
            kind: .battery,
            presentation: settings.batteryStyle == .detail ? .detail : .compact,
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

    func postLow(_ s: Snapshot) {
        center.post(NotchActivity(
            kind: .battery,
            priority: ActivityPriority.batteryLow,
            presentation: settings.batteryStyle == .detail ? .detail : .compact,
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

    func postFull(_ s: Snapshot) {
        center.post(NotchActivity(
            kind: .battery,
            presentation: settings.batteryStyle == .detail ? .detail : .compact,
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

/// 확장 상태의 배터리 페이지 (좁은 세로 배치).
struct BatteryPanel: View {
    @ObservedObject var monitor: BatteryMonitor

    var body: some View {
        if let s = monitor.snapshot {
            VStack(spacing: 4) {
                ZStack {
                    RingGauge(value: Double(s.percent) / 100, tint: s.percent <= 20 && !s.onAC ? .red : .green, lineWidth: 4.5)
                    Text("\(s.percent)%")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 52, height: 52)
                Label(s.onAC ? T("전원 어댑터", "Power Adapter") : T("배터리 전원", "Battery"),
                      systemImage: s.onAC ? "powerplug.fill" : BatteryMonitor.symbol(for: s.percent))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(statusText(s))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
            }
        } else {
            Text(T("배터리 정보를 읽을 수 없습니다", "Can't read battery info"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func statusText(_ s: BatteryMonitor.Snapshot) -> String {
        if s.isCharging, let m = s.minutesToFull { return T("완충까지 \(m / 60)시간 \(m % 60)분", "\(m / 60)h \(m % 60)m until full") }
        if s.isCharging { return T("충전 중", "Charging") }
        if s.isCharged { return T("충전 완료", "Fully Charged") }
        return s.onAC ? T("충전 대기", "Not Charging") : T("사용 중", "On Battery")
    }
}
