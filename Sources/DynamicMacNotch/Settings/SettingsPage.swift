import Foundation

/// 설정 창 페이지. 사이드바에서는 `SettingsGroup` 묶음 아래에 놓인다.
/// 기호(`symbol`)는 바꾸지 않는다 (docs/SETTINGS_REDESIGN_GUIDELINE.md §1.2, `--settings-probe`가 확인).
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, displays, permissions
    case notchControls, home, priority
    case network, bluetooth, call, airdrop
    case media, screenshot, recording, download
    case battery, focus, hud, lock, calendar
    case aiUsage, chat, agent
    case preview, about

    var id: String { rawValue }

    var group: SettingsGroup { SettingsGroup.allCases.first { $0.pages.contains(self) } ?? .app }

    var title: String {
        switch self {
        case .general: return T("일반", "General")
        case .displays: return T("디스플레이", "Displays")
        case .priority: return T("우선순위", "Priority")
        case .notchControls: return T("노치 조작", "Notch Controls")
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

    /// 페이지 머리 카드의 한 줄 설명
    var summary: String {
        switch self {
        case .general: return T("언어, 메뉴바 아이콘, 업데이트와 설정 창 모양", "Language, menu bar icon, updates and this window's look")
        case .displays: return T("노치를 띄울 화면과 화면마다 보일 내용", "Which displays show the notch and what they show")
        case .permissions: return T("기능에 필요한 macOS 권한", "macOS permissions the features need")
        case .notchControls: return T("노치를 누르고 호버할 때의 동작과 알림 시간", "How the notch responds to clicks and hover")
        case .home: return T("길게 눌러 여는 홈의 페이지와 순서", "Pages and order of Home, opened with a long-press")
        case .priority: return T("여러 상시 표시 중 무엇을 먼저 보일지", "Which Live Activity shows when several run")
        case .network: return T("Wi-Fi·VPN·핫스팟 연결 알림", "Wi-Fi, VPN and hotspot alerts")
        case .bluetooth: return T("에어팟 같은 액세서리 연결과 배터리", "AirPods and other accessories, with battery")
        case .call: return T("iPhone·FaceTime 수신 전화와 통화", "Incoming and active iPhone and FaceTime calls")
        case .airdrop: return T("끌어온 파일을 모아 두는 트레이와 에어드랍", "A tray for dragged files, and AirDrop")
        case .media: return T("재생 중인 곡과 미디어 조작", "What's playing, with media controls")
        case .screenshot: return T("찍은 스크린샷을 바로 다루는 카드", "A card to act on screenshots right away")
        case .recording: return T("화면 녹화 알림과 녹화 시간", "Screen recording alerts and elapsed time")
        case .download: return T("브라우저 다운로드 진행률", "Browser download progress")
        case .battery: return T("충전·완충·배터리 부족 알림", "Charging, full and low battery alerts")
        case .focus: return T("집중 모드가 켜지고 꺼질 때", "When a Focus turns on or off")
        case .hud: return T("음량·밝기를 바꿀 때 보이는 표시", "What you see when changing volume or brightness")
        case .lock: return T("잠금화면의 자물쇠, 미디어 위젯, 가사", "Lock screen padlock, media widget and lyrics")
        case .calendar: return T("오늘 일정과 다가오는 일정 알림", "Today's events and upcoming event alerts")
        case .aiUsage: return T("AI 사용량 한도와 이 Mac의 자원", "AI usage limits and this Mac's resources")
        case .chat: return T("노치에서 바로 묻는 AI 채팅", "Ask AI right from the notch")
        case .agent: return T("Claude Code·Codex 작업 완료 알림", "Task finished alerts from Claude Code and Codex")
        case .preview: return T("모든 알림을 노치에 띄워 보기", "Try every alert in the notch")
        case .about: return T("버전과 정보", "Version and info")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .displays: return "display.2"
        case .priority: return "list.number"
        case .notchControls: return "hand.tap"   // 2026-11 새 페이지 (일반의 '노치 조작'을 옮김)
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

/// 사이드바 묶음. 사용자가 '무엇을 하고 싶은지'로 찾게 나눈다 (docs/SETTINGS_INVENTORY.md §1-⑦).
enum SettingsGroup: String, CaseIterable, Identifiable {
    case app, notch, connection, media, system, ai, more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return T("앱", "App")
        case .notch: return T("노치", "Notch")
        case .connection: return T("연결", "Connections")
        case .media: return T("미디어·캡처", "Media & Capture")
        case .system: return T("시스템", "System")
        case .ai: return "AI"
        case .more: return T("기타", "More")
        }
    }

    var pages: [SettingsPage] {
        switch self {
        case .app: return [.general, .displays, .permissions]
        case .notch: return [.notchControls, .home, .priority]
        case .connection: return [.network, .bluetooth, .call, .airdrop]
        case .media: return [.media, .screenshot, .recording, .download]
        case .system: return [.battery, .focus, .hud, .lock, .calendar]
        case .ai: return [.aiUsage, .chat, .agent]
        case .more: return [.preview, .about]
        }
    }
}
