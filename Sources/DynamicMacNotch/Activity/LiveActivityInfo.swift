import Foundation

/// 상시 표시 항목의 설정 화면용 정보. 우선순위 목록(`persistentOrder`)은 ActivityKind 이름으로 저장된다.
extension ActivityKind {
    static func liveName(_ key: String) -> String {
        switch key {
        case "call": return T("통화", "Calls")
        case "recording": return T("화면 녹화", "Screen Recording")
        case "timer": return T("타이머", "Timer")
        case "airdrop": return T("에어드랍", "AirDrop")
        case "download": return T("다운로드", "Downloads")
        case "media": return T("미디어", "Media")
        case "hotspot": return T("핫스팟", "Hotspot")
        case "vpn": return "VPN"
        case "focusPinned": return T("집중 모드", "Focus")
        case "aiUsage": return T("AI 사용량", "AI Usage")
        case "battery": return T("충전 중", "Charging")
        case "calendar": return T("일정", "Calendar")
        default: return key
        }
    }

    static func liveSymbol(_ key: String) -> String {
        switch key {
        case "call": return "phone.fill"
        case "recording": return "record.circle"
        case "timer": return "timer"
        case "airdrop": return "airplayaudio"
        case "download": return "arrow.down.circle"
        case "media": return "music.note"
        case "hotspot": return "personalhotspot"
        case "vpn": return "network"
        case "focusPinned": return "moon"
        case "aiUsage": return "gauge.medium"
        case "battery": return "battery.100percent.bolt"
        case "calendar": return "calendar"
        default: return "circle"
        }
    }

    /// 그 기능의 상시 표시 설정이 꺼져 있어 항상 비활성인 항목
    func liveDisabled(in settings: AppSettings) -> Bool {
        switch self {
        case .vpn: return !settings.vpnPinned
        case .hotspot: return !settings.hotspotPinned
        case .focusPinned: return !settings.focusPinned
        case .aiUsage: return !settings.aiUsagePinned
        case .battery: return !settings.batteryChargingPinned
        case .calendar: return !settings.calendarPinned
        default: return false
        }
    }
}
