import Foundation

// 설정에 저장되는 선택지. rawValue가 저장값이므로 이미 있는 값의 이름을 바꾸면 안 된다.

enum HapticStrength: String, CaseIterable, Identifiable {
    case off, weak, strong
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return T("끄기", "Off")
        case .weak: return T("약", "Light")
        case .strong: return T("강", "Strong")
        }
    }
}

/// 일회성 알림: 컴팩트(좌우로만 넓어짐) / 상세(좌우·아래로 커짐)
enum AlertStyle: String, CaseIterable, Identifiable {
    case compact, detail
    var id: String { rawValue }
    var label: String { self == .compact ? T("컴팩트", "Compact") : T("상세", "Detailed") }
}

enum BatteryDisplay: String, CaseIterable, Identifiable {
    case percent, ring, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .percent: return T("백분율", "Percent")
        case .ring: return T("원형", "Ring")
        case .both: return T("둘 다", "Both")
        }
    }
}

enum HUDStyle: String, CaseIterable, Identifiable {
    case number, bar, ring
    var id: String { rawValue }
    var label: String {
        switch self {
        case .number: return T("숫자", "Number")
        case .bar: return T("가로 바", "Bar")
        case .ring: return T("원형", "Ring")
        }
    }
}

enum ProgressStyle: String, CaseIterable, Identifiable {
    case percent, ring
    var id: String { rawValue }
    var label: String { self == .percent ? T("백분율", "Percent") : T("원형", "Ring") }
}

enum ScreenshotSource: String, CaseIterable, Identifiable {
    case clipboard, file, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .clipboard: return T("클립보드", "Clipboard")
        case .file: return T("파일", "File")
        case .both: return T("둘 다", "Both")
        }
    }
}

/// 화면 녹화 표시: 잠깐 알림 후 들어감 / 녹화 내내 노치에 표시(왼쪽 녹화 시간)
enum RecordingStyle: String, CaseIterable, Identifiable {
    case brief, persistent
    var id: String { rawValue }
    var label: String { self == .brief ? T("잠깐 알림", "Brief Alert") : T("계속 표시", "Keep Showing") }
}

/// 에어드랍·트레이: 사용 / 노치 홈에서 가림(파일을 끌어오면 여전히 동작) / 끄기(끌어와도 동작 안 함)
enum TrayMode: String, CaseIterable, Identifiable {
    case on, hidden, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .on: return T("사용", "On")
        case .hidden: return T("홈에서 가림", "Hide in Home")
        case .off: return T("끄기", "Off")
        }
    }
}

/// 파일을 끌어왔을 때 먼저 보일 화면
enum FileDragPage: String, CaseIterable, Identifiable {
    case tray, chat
    var id: String { rawValue }
    var label: String { self == .tray ? T("에어드랍·트레이", "AirDrop & Tray") : T("AI 채팅", "AI Chat") }
}

/// 일회성 알림이 뜨는 범위
enum AlertScope: String, CaseIterable, Identifiable {
    case main, all
    var id: String { rawValue }
    var label: String { self == .main ? T("주 디스플레이만", "Main Display Only") : T("노치를 켠 모든 디스플레이", "All Displays with a Notch") }
}

/// AI 채팅 페이지로 돌아왔을 때: 마지막 답변 / 처음 화면(입력 칸만, 목록 닫힘)
enum ChatReopen: String, CaseIterable, Identifiable {
    case lastAnswer, fresh
    var id: String { rawValue }
    var label: String { self == .lastAnswer ? T("마지막 답변", "Last Answer") : T("처음 화면", "New Chat Screen") }
}

/// AI 사용량 표시 형태
enum UsageStyle: String, CaseIterable, Identifiable {
    case text, ring
    var id: String { rawValue }
    var label: String { self == .text ? T("텍스트", "Text") : T("원형", "Ring") }
}
