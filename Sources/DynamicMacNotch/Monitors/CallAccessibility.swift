import AppKit
import ApplicationServices
import SwiftUI

// 통화 배너·통화 창에서 수락·거절·끊기·음소거 버튼과 상대 이름을 찾는다 (손쉬운 사용)

/// 누를 수 있는 손쉬운 사용 요소 (버튼 또는 이름 붙은 동작)
struct AXControl {
    let element: AXUIElement
    let action: String

    func press() { AXUIElementPerformAction(element, action as CFString) }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }

    private static let acceptWords = ["수락", "받기", "응답", "accept", "answer"]
    private static let declineWords = ["거절", "decline", "reject"]
    private static let endWords = ["끊기", "통화 종료", "종료", "end call", "end", "hang up"]
    /// macOS 통화 배너의 음소거 버튼은 '소리 끔'(음소거 해제 상태에서는 '소리 켬')으로 나온다
    private static let muteWords = ["음소거", "소리 끔", "소리 켬", "mute", "unmute"]
    private static let unmuteWords = ["소리 켬", "음소거 해제", "unmute"]
    /// '거절하고 메시지 보내기' 같은 다른 거절 버튼은 건너뛴다
    private static let declineExclude = ["메시지", "message", "음성"]
    /// 이름 후보에서 뺄 글자 (앱·버튼 이름 등)
    private static let noise = ["전화", "phone", "facetime", "수신 전화", "incoming call", "오디오", "audio", "알림", "notification",
                                "휴대폰", "mobile", "iphone", "통화", "call"]

    struct Found {
        var accept: AXControl?, decline: AXControl?, end: AXControl?, mute: AXControl?
        var muted: Bool?
        var name: String?
        /// 배너 설명에서 읽은 상대 이름(저장된 연락처) 또는 전화번호
        var caller: String?
        /// 창 안에 전화·통화 관련 글이 있었는지
        var callContext = false
    }

    /// "이름, 부가 설명 - 0:12" → "이름". 방향 표시 같은 보이지 않는 문자는 지운다.
    /// 부가 설명(iPhone으로부터 전달됨 등)이 붙은 칸만 상대 칸으로 본다.
    static func callerName(from description: String) -> String? {
        let invisible = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        let clean = String(description.unicodeScalars.filter { !invisible.contains($0) })
        let parts = clean.components(separatedBy: ", ")
        guard parts.count >= 2 else { return nil }
        let rest = parts.dropFirst().joined(separator: ", ").lowercased()
        guard ["iphone", "전달", "forward", "facetime", "휴대전화", "mobile", "전화", "phone"].contains(where: rest.contains) else { return nil }
        var name = parts[0].trimmingCharacters(in: .whitespaces)
        if let r = name.range(of: #" - \d+:\d{2}(:\d{2})?$"#, options: .regularExpression) { name.removeSubrange(r) }
        return name.isEmpty ? nil : name
    }

    /// 창 안에서 수락·거절·끊기·음소거 조작과 상대 이름을 찾는다.
    static func search(_ root: AXUIElement) -> Found {
        var found = Found()
        var texts: [String] = []
        var context = ""
        var visited = 0
        // 요소 하나의 속성을 한 번에 읽는다 (속성마다 따로 물으면 요소당 왕복이 8번이라 창이 크면 수십 ms가 든다)
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXIdentifier",
                     kAXValueAttribute, kAXChildrenAttribute] as CFArray
        func attributes(_ el: AXUIElement) -> [Any?] {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let list = values as? [Any], list.count == 7 else { return Array(repeating: nil, count: 7) }
            return list
        }
        // 한글은 포함 여부로, 영어는 단어 단위로 (예: "end"가 "calendar"에 걸리지 않게)
        func matches(_ text: String, _ words: [String]) -> Bool {
            words.contains { w in
                if w.range(of: "[a-z]", options: .regularExpression) == nil { return text.contains(w) }
                return text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: w))\\b", options: .regularExpression) != nil
            }
        }
        func walk(_ el: AXUIElement, depth: Int) {
            visited += 1
            guard depth < 16, visited < 600 else { return }
            let a = attributes(el)
            let role = a[0] as? String ?? ""
            var actionsRef: CFArray?
            AXUIElementCopyActionNames(el, &actionsRef)
            let actions = (actionsRef as? [String]) ?? []
            let text = a[1...4].compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " ").lowercased()
            context += " " + text
            // 버튼만 이름으로 분류 (상대 이름 칸도 누를 수 있는 요소라, 이름이 '응답센터'여도 버튼으로 보지 않게)
            if role == kAXButtonRole as String || role == "AXCheckBox" {
                if found.accept == nil, matches(text, acceptWords) { found.accept = AXControl(element: el, action: kAXPressAction) }
                else if matches(text, declineWords) {
                    if found.decline == nil, !matches(text, declineExclude) { found.decline = AXControl(element: el, action: kAXPressAction) }
                } else if found.mute == nil, matches(text, muteWords) {
                    found.mute = AXControl(element: el, action: kAXPressAction)
                    if let n = a[5] as? NSNumber {
                        found.muted = n.boolValue
                    } else {
                        found.muted = matches(text, unmuteWords)   // '소리 켬'이 보이면 지금 음소거 상태
                    }
                } else if found.end == nil, matches(text, endWords) { found.end = AXControl(element: el, action: kAXPressAction) }
            } else if found.caller == nil, let desc = a[2] as? String, let caller = Self.callerName(from: desc) {
                // 통화 배너의 상대 칸: "홍길동, iPhone으로부터 전달됨" / "‪010-0000-0000‬, iPhone으로부터 전달됨 - 0:12"
                found.caller = caller
            }
            // 알림 배너의 사용자 정의 동작 (예: "수락", "거절")
            for action in actions where !action.hasPrefix("AX") || action.contains("Name:") {
                let lower = action.lowercased()
                if found.accept == nil, matches(lower, acceptWords) { found.accept = AXControl(element: el, action: action) }
                if found.decline == nil, matches(lower, declineWords) { found.decline = AXControl(element: el, action: action) }
            }
            // 이름 후보: 짧은 글자(정적 텍스트·설명)
            if role == kAXStaticTextRole as String || role == "AXHeading", let s = a[5] as? String { texts.append(s) }
            for c in (a[6] as? [AXUIElement]) ?? [] { walk(c, depth: depth + 1) }
        }
        walk(root, depth: 0)
        // 캘린더 초대처럼 '수락/거절'이 있는 다른 알림은 통화로 보지 않는다
        let callContext = ["전화", "통화", "facetime", "phone", "call"].contains { (context + " " + texts.joined(separator: " ").lowercased()).contains($0) }
        found.callContext = callContext
        if !callContext { found.accept = nil; found.decline = nil; found.end = nil; found.mute = nil }
        found.name = found.caller ?? texts.first { t in
            let l = t.lowercased().trimmingCharacters(in: .whitespaces)
            return !l.isEmpty && l.count <= 40 && !noise.contains(l) && !l.contains(":") && l.rangeOfCharacter(from: .letters) != nil
        }
        return found
    }
}
