import SwiftUI

/// 우클릭 메뉴의 '테스트 액티비티'. 2단계 모니터가 붙기 전에 애니메이션과 레이아웃을 확인하는 용도.
enum DemoActivity: String, CaseIterable {
    case wifi, wifiDetail, offline, vpn, bluetoothCompact, bluetoothLow, bluetoothNoBattery, bluetoothDetail, focus, volume, brightness, charger, low, recording

    var menuTitle: String {
        switch self {
        case .wifi: return T("Wi-Fi 연결됨 (컴팩트)", "Wi-Fi Connected (Compact)")
        case .wifiDetail: return T("Wi-Fi 연결됨 (상세)", "Wi-Fi Connected (Detail)")
        case .offline: return T("네트워크 끊김", "Network Lost")
        case .vpn: return T("VPN 연결 해제됨", "VPN Disconnected")
        case .bluetoothCompact: return T("AirPods 연결 (컴팩트)", "AirPods Connected (Compact)")
        case .bluetoothLow: return T("마우스 연결 (배터리 12%)", "Mouse Connected (12% Battery)")
        case .bluetoothNoBattery: return T("게임패드 연결 (배터리 정보 없음)", "Gamepad Connected (No Battery Info)")
        case .bluetoothDetail: return T("AirPods 연결 (상세)", "AirPods Connected (Detail)")
        case .focus: return T("집중 모드 켜짐", "Focus On")
        case .volume: return T("음량 HUD", "Volume HUD")
        case .brightness: return T("밝기 HUD", "Brightness HUD")
        case .charger: return T("충전기 연결", "Charger Connected")
        case .low: return T("배터리 부족", "Low Battery")
        case .recording: return T("화면 녹화 (5초)", "Screen Recording (5s)")
        }
    }

    func run(center: ActivityCenter, battery: BatteryMonitor) {
        switch self {
        case .wifi:
            center.post(NotchActivity(kind: .network, symbol: "wifi", tint: .blue, value: .text(T("연결됨", "Connected")), title: "Wi-Fi", subtitle: "Home_5G", wing: 60))
        case .vpn:
            center.post(NotchActivity(kind: .network, symbol: "lock.shield", tint: .gray, value: .text(T("해제됨", "Disconnected")), title: "VPN", subtitle: T("연결 해제됨", "Disconnected"), wing: 60))
        case .bluetoothCompact:
            center.post(NotchActivity(kind: .bluetooth, symbol: "airpodspro", tint: .green, value: .percent(0.82), wing: 56, valueTint: .green))
        case .bluetoothLow:
            center.post(NotchActivity(kind: .bluetooth, symbol: "computermouse", tint: .red, value: .percent(0.12), wing: 56, valueTint: .red))
        case .bluetoothNoBattery:
            center.post(NotchActivity(kind: .bluetooth, symbol: "gamecontroller.fill", tint: .green, value: .text(T("연결됨", "Connected")),
                                      wing: NetworkMonitor.wing(for: T("연결됨", "Connected")), valueTint: .white))
        case .offline:
            center.post(NotchActivity(kind: .network, presentation: .detail, duration: 4,
                                      symbol: "antenna.radiowaves.left.and.right.slash", tint: .orange,
                                      value: .text(T("없음", "None")), title: T("연결된 네트워크 없음", "No Network Connection"), subtitle: T("Wi-Fi·셀룰러 연결이 끊겼습니다", "Wi-Fi and cellular are disconnected")))
        case .wifiDetail:
            center.post(NotchActivity(kind: .network, presentation: .detail, symbol: "wifi", tint: .blue,
                                      value: .text(T("연결됨", "Connected")), title: "Wi-Fi", subtitle: "Home_5G", wing: 60))
        case .bluetoothDetail:
            center.post(NotchActivity(kind: .bluetooth, presentation: .detail, symbol: "airpodspro", tint: .white,
                                      value: .percent(0.82), title: "AirPods Pro", subtitle: T("연결됨", "Connected"),
                                      detailValue: .ring(0.82)))
        case .focus:
            center.post(NotchActivity(kind: .focus, symbol: "moon.fill", tint: .indigo, value: .text(T("켬", "On")), title: T("방해금지 모드", "Do Not Disturb"), subtitle: T("집중 모드 켜짐", "Focus On"), wing: 44))
        case .volume:
            // 연속 조절처럼 값만 갱신되는지 확인한다.
            for (i, v) in [0.40, 0.46, 0.53, 0.60].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) {
                    let value: ActivityValue = switch AppSettings.shared.hudStyle {
                    case .number: .bigNumber(v)
                    case .bar: .bar(v)
                    case .ring: .ring(v)
                    }
                    center.post(NotchActivity(kind: .hud, priority: ActivityPriority.hud, duration: 1.5,
                                              symbol: "speaker.wave.2.fill", value: value, wing: 64))
                }
            }
        case .brightness:
            center.post(NotchActivity(kind: .hud, priority: ActivityPriority.hud, duration: 1.5,
                                      symbol: "sun.max.fill", tint: .yellow,
                                      value: AppSettings.shared.hudStyle == .number ? .bigNumber(0.7) : .ring(0.7), wing: 56))
        case .charger:
            battery.postCharger(BatteryMonitor.read() ?? .init(percent: 64, isCharging: true, onAC: true, isCharged: false, minutesToFull: 48))
        case .low:
            battery.postLow(.init(percent: 18, isCharging: false, onAC: false, isCharged: false))
        case .recording:
            center.setPersistent(NotchActivity(kind: .demo, priority: ActivityPriority.recording, symbol: "record.circle",
                                               tint: .red, value: .recordingDot, title: T("화면 녹화", "Screen Recording"), wing: 44))
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { center.removePersistent(.demo) }
        }
    }
}
