import Foundation

/// 앱 언어 (설정 > 일반 > 언어). 앱을 시작할 때 한 번 정해지며, 바꾸면 앱을 다시 시작해 적용한다.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, korean, english
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return T("시스템 설정 따름", "System default")
        case .korean: return "한국어"
        case .english: return "English"
        }
    }
}

enum L10n {
    static let languageKey = "language"

    /// 이번 실행에서 영어로 표시하는지
    static let isEnglish: Bool = {
        switch AppLanguage(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .system {
        case .korean: return false
        case .english: return true
        case .system:
            // 시스템 선호 언어가 한국어면 한국어, 그 밖에는 영어
            return !(Locale.preferredLanguages.first ?? "en").hasPrefix("ko")
        }
    }()

    /// "1.5초" / "1.5s"
    static func seconds(_ value: Double, digits: Int) -> String {
        let n = String(format: "%.\(digits)f", value)
        return isEnglish ? "\(n)s" : "\(n)초"
    }
}

/// 화면에 보이는 글자: 한국어와 영어를 함께 적고 현재 언어에 맞는 쪽을 쓴다.
@inline(__always)
func T(_ korean: String, _ english: String) -> String {
    L10n.isEnglish ? english : korean
}
