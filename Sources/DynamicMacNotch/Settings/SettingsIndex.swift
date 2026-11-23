import Foundation

/// 설정 검색의 한 항목: 페이지 하나 또는 페이지 안의 줄 하나.
/// 글은 한국어·영어를 모두 가진다 (앱 언어와 상관없이 둘 다로 찾는다).
struct SettingsEntry: Identifiable {
    var page: SettingsPage
    var section: (ko: String, en: String)?
    var title: (ko: String, en: String)
    var detail: (ko: String, en: String)?
    /// 이 줄이 바꾸는 설정 (`@Setting` 이름). 페이지 항목은 비어 있다
    var keys: [String]
    /// 페이지 자체 (줄이 아님)
    var isPage = false

    /// 겹치지 않는 이름: 페이지는 `페이지`, 줄은 `페이지.줄 이름`
    var id: String { isPage ? page.rawValue : page.rawValue + "." + title.ko }

    /// 지금 언어의 글
    var shownTitle: String { T(title.ko, title.en) }
    var shownDetail: String? { detail.map { T($0.ko, $0.en) } }
    var shownSection: String? { section.map { T($0.ko, $0.en) } }
}

/// 설정 검색 색인. 대부분은 페이지 코드에서 자동으로 만든다 (`SettingsIndex+Generated.swift`, scripts/gen-settings-index.py).
enum SettingsIndex {
    /// 이름이 실행 중에 정해지는 줄(디스플레이 이름, 왼쪽·오른쪽 칸 등)과 순서 목록처럼 자동으로 못 읽는 줄
    static let manual: [SettingsEntry] = [
        SettingsEntry(page: .displays, section: ("디스플레이별 상시 표시", "Live Activity by Display"), title: ("디스플레이마다 보일 상시 표시", "Live Activity for each display"),
                      detail: nil, keys: ["displayContent"]),
        SettingsEntry(page: .displays, section: ("디스플레이별 알림", "Alerts by Display"), title: ("중요한 알림 항목", "Important Alerts"),
                      detail: nil, keys: ["criticalAlertAdded", "criticalAlertRemoved"]),
        SettingsEntry(page: .priority, section: nil, title: ("상시 표시 우선순위", "Live Activity priority"),
                      detail: ("위에 있는 항목이 먼저 보입니다.", "Higher items show first."), keys: ["persistentOrder"]),
        SettingsEntry(page: .home, section: nil, title: ("홈 페이지 순서", "Home page order"),
                      detail: ("끌어서 순서를 바꾸고 기능을 켜고 끕니다.", "Drag to reorder and turn features on or off."), keys: ["homeOrder", "homeDisabled"]),
        SettingsEntry(page: .airdrop, section: ("표시", "Show"), title: ("끌어올 때 보일 화면", "When dragging files"), detail: nil, keys: ["fileDragPage"]),
        SettingsEntry(page: .aiUsage, section: ("표시 방식", "Appearance"), title: ("꾹 눌렀을 때 보일 내용", "On long-press, show"), detail: nil, keys: ["monitorExpand"]),
        SettingsEntry(page: .aiUsage, section: ("상시 표시", "Live Activity"), title: ("왼쪽·오른쪽 칸", "Left and right sides"),
                      detail: ("노치 양옆에 보일 한도나 지표", "Limits or metrics beside the notch"),
                      keys: ["resourceLeft", "resourceRight", "bothLeft", "bothRight", "aiUsageSides"]),
        SettingsEntry(page: .aiUsage, section: ("세부 설정", "Details"), title: ("AI 서비스 로그인", "AI service sign-in"),
                      detail: ("Claude·ChatGPT·Gemini 계정 연결", "Connect Claude, ChatGPT and Gemini"), keys: ["aiConnected"]),
        SettingsEntry(page: .chat, section: nil, title: ("모델", "Model"), detail: ("서비스마다 쓸 모델", "The model for each service"),
                      keys: ["chatModelClaude", "chatModelOpenAI", "chatModelGemini"]),
        SettingsEntry(page: .chat, section: nil, title: ("API 키", "API key"), detail: ("키체인에 저장하는 서비스 키", "Service key stored in the Keychain"), keys: []),
        SettingsEntry(page: .chat, section: ("답변", "Answers"), title: ("답변 지침", "Answer instructions"),
                      detail: ("모든 답변에 적용할 지침", "Instructions applied to every answer"), keys: ["chatInstructions"]),
    ]

    /// 설정 화면에 줄이 없는 내부 상태 (검색 대상이 아님)
    static let internalKeys: Set<String> = ["onboardingDone", "settingsCollapsedGroups", "settingsLastPage"]

    /// 페이지 + 자동 색인 + 손으로 적은 줄. 같은 줄(같은 id)이면 설정 이름만 합친다.
    static let all: [SettingsEntry] = {
        var list = pages + rows
        for extra in manual {
            if let i = list.firstIndex(where: { $0.id == extra.id }) {
                list[i].keys += extra.keys.filter { !list[i].keys.contains($0) }
                if list[i].detail == nil { list[i].detail = extra.detail }
            } else {
                list.append(extra)
            }
        }
        return list
    }()

    // MARK: - 찾기

    /// 같은 뜻의 말. 한 묶음의 어느 말로 찾아도 나머지 말이 들어간 줄이 나온다.
    static let synonyms: [[String]] = [
        ["음량", "볼륨", "소리", "volume", "sound"],
        ["밝기", "명도", "brightness"],
        ["wi-fi", "wifi", "와이파이", "무선"],
        ["블루투스", "bluetooth", "에어팟", "airpods", "액세서리", "accessory"],
        ["투명", "투명도", "transparency", "흐림", "blur", "유리", "glass"],
        ["알림", "alert", "alerts", "notification"],
        ["상시", "live", "고정", "pinned"],
        ["업데이트", "update"],
        ["메뉴바", "메뉴 막대", "menu bar"],
        ["호버", "hover", "마우스", "mouse"],
        ["햅틱", "haptic", "진동"],
        ["언어", "language", "영어", "english", "한국어", "korean"],
        ["배터리", "battery", "충전", "charging", "charger"],
        ["녹화", "recording", "record"],
        ["스크린샷", "screenshot", "캡처", "캡쳐", "capture"],
        ["다운로드", "download"],
        ["가사", "lyrics"],
        ["일정", "calendar", "캘린더", "event"],
        ["채팅", "chat", "gpt", "claude", "gemini", "codex"],
        ["카메라", "camera", "거울", "mirror"],
        ["디스플레이", "display", "모니터", "monitor", "화면"],
        ["메모리", "memory", "ram"],
        ["전체 화면", "전체화면", "full screen", "fullscreen"],
        ["잠금", "lock"],
        ["에어드랍", "airdrop", "트레이", "tray"],
        ["집중", "focus", "방해금지"],
        ["통화", "전화", "call", "facetime"],
        ["시간", "duration", "초"],
        ["권한", "permission", "permissions"],
        ["다크", "dark", "어두운"],
    ]

    /// 비교용 정리: 한글 조합 형태를 맞추고(NFC) 대소문자·발음 기호를 무시한다
    static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 한글 첫소리(초성)만 뽑는다: "음량" → "ㅇㄹ"
    static func initials(_ s: String) -> String {
        let table = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
        return String(s.unicodeScalars.compactMap { u -> Character? in
            let v = Int(u.value)
            guard (0xAC00...0xD7A3).contains(v) else { return u.properties.isWhitespace ? nil : Character(u) }
            return table[(v - 0xAC00) / 588]
        })
    }

    private static func isInitialsOnly(_ q: String) -> Bool {
        !q.isEmpty && q.unicodeScalars.allSatisfy { (0x3131...0x314E).contains(Int($0.value)) }
    }

    /// 검색어와 그 같은 뜻의 말들
    static func alternatives(_ query: String) -> [String] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        var result = [q]
        for group in synonyms where group.contains(where: { $0.hasPrefix(q) || q.contains($0) && $0.count > 1 }) {
            for word in group where !result.contains(word) { result.append(word) }
        }
        return result
    }

    /// 검색 결과. 이름이 검색어로 시작하면 먼저, 그다음 이름에 들어 있으면, 그다음 설명·구역·페이지.
    static func search(_ query: String, in entries: [SettingsEntry] = all) -> [SettingsEntry] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        let words = alternatives(q)
        let initialsQuery = isInitialsOnly(q) ? q : nil
        var scored: [(SettingsEntry, Int, Int)] = []
        for (index, e) in entries.enumerated() {
            let names = [e.title.ko, e.title.en].map(normalize)
            let others = ([e.detail?.ko, e.detail?.en, e.section?.ko, e.section?.en].compactMap { $0 }
                          + [e.page.title, SettingsIndex.pageTitleOther(e.page)]).map(normalize)
            var score: Int?
            if names.contains(where: { $0.hasPrefix(q) }) { score = 0 }
            else if names.contains(where: { $0.contains(q) }) { score = 1 }
            else if let iq = initialsQuery, initials(e.title.ko).contains(iq) { score = 1 }
            else if words.dropFirst().contains(where: { w in names.contains { $0.contains(w) } }) { score = 2 }
            else if words.contains(where: { w in others.contains { $0.contains(w) } }) { score = 3 }
            if let score { scored.append((e, score, index)) }
        }
        return scored.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
    }

    /// 페이지 이름의 다른 언어 (지금 언어의 이름은 `page.title`)
    static func pageTitleOther(_ page: SettingsPage) -> String {
        guard let p = pages.first(where: { $0.page == page }) else { return "" }
        return L10n.isEnglish ? p.title.ko : p.title.en
    }
}
