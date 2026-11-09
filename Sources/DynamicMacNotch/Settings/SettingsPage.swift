import Foundation

/// 설정 창 페이지. '상호작용'은 기능별 페이지를 펼치는 묶음이다.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, displays, priority, interaction
    case home, network, bluetooth, focus, call, media, download, airdrop, screenshot, recording, battery, hud, lock, calendar, aiUsage, chat, agent
    case preview, permissions, about

    var id: String { rawValue }

    /// 사이드바 맨 위 단계
    static let top: [SettingsPage] = [.general, .displays, .priority, .interaction, .preview, .permissions, .about]
    /// '상호작용' 아래에 펼쳐지는 기능별 페이지
    static let features: [SettingsPage] = [.home, .network, .bluetooth, .focus, .call, .media, .download, .airdrop,
                                           .screenshot, .recording, .battery, .hud, .lock, .calendar, .aiUsage, .chat, .agent]

    var title: String {
        switch self {
        case .general: return T("일반", "General")
        case .displays: return T("디스플레이", "Displays")
        case .priority: return T("우선순위", "Priority")
        case .interaction: return T("상호작용", "Interactions")
        case .home: return T("홈 기능", "Home Features")
        case .network: return T("네트워크", "Network")
        case .bluetooth: return T("블루투스", "Bluetooth")
        case .focus: return T("집중 모드", "Focus")
        case .call: return T("통화", "Calls")
        case .media: return T("미디어", "Media")
        case .download: return T("다운로드", "Downloads")
        case .airdrop: return T("에어드랍·트레이", "AirDrop & Tray")
        case .screenshot: return T("스크린샷", "Screenshots")
        case .recording: return T("화면 녹화", "Screen Recording")
        case .battery: return T("배터리", "Battery")
        case .hud: return "HUD"
        case .lock: return T("잠금화면", "Lock Screen")
        case .calendar: return T("일정", "Calendar")
        case .aiUsage: return T("실시간 모니터링", "Live Monitoring")
        case .chat: return T("AI 채팅", "AI Chat")
        case .agent: return "Claude Code · Codex"
        case .preview: return T("미리보기", "Preview")
        case .permissions: return T("권한 관리", "Permissions")
        case .about: return T("정보", "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .displays: return "display.2"
        case .priority: return "list.number"
        case .interaction: return "bell.badge"
        case .home: return "square.grid.2x2"
        case .network: return "wifi"
        case .bluetooth: return "airpodspro"
        case .focus: return "moon"
        case .call: return "phone"
        case .media: return "music.note"
        case .download: return "arrow.down.circle"
        case .airdrop: return "tray.and.arrow.down"
        case .screenshot: return "camera.viewfinder"
        case .recording: return "record.circle"
        case .battery: return "battery.75percent"
        case .hud: return "speaker.wave.2"
        case .lock: return "lock"
        case .calendar: return "calendar"
        case .aiUsage: return "gauge.medium"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .agent: return "terminal"
        case .preview: return "play.rectangle"
        case .permissions: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}
