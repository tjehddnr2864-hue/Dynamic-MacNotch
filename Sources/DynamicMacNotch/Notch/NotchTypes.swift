import Foundation

enum NotchState: Int, Equatable {
    case idle, compact, detail, expanded
}

/// 홈 페이지. 한 번에 하나씩 표시하고 점·스와이프로 넘긴다.
enum HomeOption: Int, CaseIterable {
    // rawValue는 예전 저장값(번호)과 맞아야 하므로 새 페이지는 끝에 붙인다
    case camera, timer, usage, memo, calendar, tray, chat, resource

    /// 설정·저장에 쓰는 이름 (순서를 바꿔도 변하지 않음)
    var key: String {
        switch self {
        case .camera: return "camera"
        case .timer: return "timer"
        case .usage: return "usage"
        case .memo: return "memo"
        case .calendar: return "calendar"
        case .tray: return "tray"
        case .chat: return "chat"
        case .resource: return "resource"
        }
    }

    init?(key: String) {
        guard let o = HomeOption.allCases.first(where: { $0.key == key }) else { return nil }
        self = o
    }

    var title: String {
        switch self {
        case .camera: return T("카메라", "Camera")
        case .timer: return T("타이머", "Timer")
        case .usage: return T("AI 사용량", "AI Usage")
        case .memo: return T("메모", "Memo")
        case .calendar: return T("오늘 일정", "Today")
        case .tray: return T("에어드랍·트레이", "AirDrop & Tray")
        case .chat: return T("AI 채팅", "AI Chat")
        case .resource: return T("자원 사용량", "Resource Usage")
        }
    }

    var symbol: String {
        switch self {
        case .camera: return "camera.fill"
        case .timer: return "timer"
        case .usage: return "gauge.medium"
        case .memo: return "note.text"
        case .calendar: return "calendar"
        case .tray: return "tray.and.arrow.down.fill"
        case .chat: return "bubble.left.and.text.bubble.right.fill"
        case .resource: return "cpu"
        }
    }
}

enum ExpandedPage: Equatable {
    case home
    case activity(ActivityKind)
}
