import AppKit

/// 재생 길이·위치를 알려 주지 않는 브라우저(Firefox 계열의 YouTube 등)에서
/// 손쉬운 사용 권한으로 웹 페이지의 재생 막대(슬라이더)를 찾아 위치를 읽고 옮긴다.
/// 모든 호출은 백그라운드에서 한다 (찾기는 곡마다 한 번, 0.1초 안팎).
enum BrowserPosition {
    /// 음량 막대는 뺀다 (여러 언어)
    private static let volumeWords = ["volume", "볼륨", "음량", "音量", "lautstärke", "volumen"]

    /// 재생 막대 찾기. 곡 제목이 창 제목에 들어 있는 창을 먼저 본다.
    static func findSlider(pid: pid_t, title: String, limit: Int = 20000) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var windows = (copy(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let wanted = title.lowercased()
        windows.sort { a, _ in ((copy(a, kAXTitleAttribute) as? String) ?? "").lowercased().contains(wanted) }
        var visited = 0
        for window in windows {
            var stack = [window]
            while let element = stack.popLast(), visited < limit {
                visited += 1
                if copy(element, kAXRoleAttribute) as? String == "AXSlider", isSeekSlider(element) { return element }
                if let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] { stack += children.reversed() }
            }
        }
        return nil
    }

    private static func isSeekSlider(_ element: AXUIElement) -> Bool {
        let label = [copy(element, kAXDescriptionAttribute), copy(element, kAXTitleAttribute)].compactMap { $0 as? String }.joined(separator: " ").lowercased()
        guard !volumeWords.contains(where: label.contains) else { return false }
        guard let max = number(copy(element, kAXMaxValueAttribute)), max > 0, number(copy(element, kAXValueAttribute)) != nil else { return false }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    /// (현재 위치, 전체 길이) 초. 막대가 사라졌으면 nil
    static func read(_ slider: AXUIElement) -> (position: Double, duration: Double)? {
        guard let value = number(copy(slider, kAXValueAttribute)), let max = number(copy(slider, kAXMaxValueAttribute)), max > 0 else { return nil }
        return (min(value, max), max)
    }

    @discardableResult
    static func seek(_ slider: AXUIElement, to seconds: Double) -> Bool {
        AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, NSNumber(value: seconds.rounded())) == .success
    }

    private static func copy(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func number(_ value: CFTypeRef?) -> Double? { (value as? NSNumber)?.doubleValue }
}
