import AppKit

/// 수식 이미지. 복사할 때는 원문(LaTeX)으로 되돌린다.
final class MathAttachment: NSTextAttachment {
    /// 구분 기호까지 포함한 원문 (예: $x^2$)
    var source = ""
    /// 줄이지 않았을 때의 크기
    var naturalBounds = CGRect.zero
}

/// 답변 Markdown을 노치에 표시할 글자로 바꾼다.
/// 수식·밑줄은 Markdown에 없으므로 먼저 표식으로 바꿔 두었다가 변환 뒤에 되돌린다 (수식 안의 _·*가 서식으로 해석되지 않게).
enum ChatMarkdown {
    private static let bodySize: CGFloat = 12
    private static let textColor = NSColor.white.withAlphaComponent(0.92)
    private static let secondaryColor = NSColor.white.withAlphaComponent(0.6)
    private static let codeBackground = NSColor.white.withAlphaComponent(0.1)
    private static let codeKey = NSAttributedString.Key("chatCode")

    private static let mathOpen: Character = "\u{E000}"
    private static let mathClose: Character = "\u{E001}"
    private static let underlineOpen: Character = "\u{E002}"
    private static let underlineClose: Character = "\u{E003}"

    private struct Math {
        var latex: String
        var source: String
        var display: Bool
    }

    /// 표시 폭 (수식이 이보다 넓으면 줄인다)
    static func render(_ markdown: String, maxWidth: CGFloat) -> NSAttributedString {
        let (prepared, formulas) = extract(markdown)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: prepared, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: textColor])
        }
        let output = convert(parsed)
        applyUnderlines(output)
        detectLinks(output)
        insertFormulas(formulas, into: output, maxWidth: maxWidth)
        return output
    }

    // MARK: - 수식·밑줄 꺼내기

    /// 코드 블록·코드 조각 안은 건드리지 않는다
    private static func extract(_ text: String) -> (String, [Math]) {
        let chars = Array(text)
        var output = "", formulas: [Math] = []
        var i = 0, inFence = false, atLineStart = true
        func starts(_ s: String, at index: Int) -> Bool {
            let pattern = Array(s)
            return index + pattern.count <= chars.count && Array(chars[index..<index + pattern.count]) == pattern
        }
        func find(_ s: String, from index: Int) -> Int? {
            var j = index
            while j < chars.count {
                if chars[j] == "\\" {
                    if starts(s, at: j) { return j }
                    j += 2
                    continue
                }
                if starts(s, at: j) { return j }
                j += 1
            }
            return nil
        }
        func addMath(_ latex: ArraySlice<Character>, source: ArraySlice<Character>, display: Bool) {
            output.append(mathOpen)
            output += String(formulas.count)
            output.append(mathClose)
            formulas.append(Math(latex: String(latex).trimmingCharacters(in: .whitespacesAndNewlines), source: String(source), display: display))
        }
        while i < chars.count {
            let c = chars[i]
            if atLineStart, starts("```", at: i) || starts("~~~", at: i) { inFence.toggle() }
            atLineStart = c == "\n"
            if inFence {
                output.append(c)
                i += 1
                continue
            }
            if c == "`" {
                // 같은 길이의 ` 묶음까지 그대로 옮긴다
                var n = 0
                while i + n < chars.count, chars[i + n] == "`" { n += 1 }
                let fence = String(repeating: "`", count: n)
                var j = i + n
                while j < chars.count, !starts(fence, at: j) { j += 1 }
                let end = min(j + n, chars.count)
                output += String(chars[i..<end])
                i = end
                continue
            }
            if starts("<u>", at: i) {
                output.append(underlineOpen)
                i += 3
                continue
            }
            if starts("</u>", at: i) {
                output.append(underlineClose)
                i += 4
                continue
            }
            if starts("\\[", at: i), let end = find("\\]", from: i + 2) {
                addMath(chars[i + 2..<end], source: chars[i..<end + 2], display: true)
                i = end + 2
                continue
            }
            if starts("\\(", at: i), let end = find("\\)", from: i + 2) {
                addMath(chars[i + 2..<end], source: chars[i..<end + 2], display: false)
                i = end + 2
                continue
            }
            if c == "\\", i + 1 < chars.count {   // \$ 등 이스케이프는 Markdown에 맡긴다
                output.append(c)
                output.append(chars[i + 1])
                i += 2
                continue
            }
            if starts("$$", at: i), let end = find("$$", from: i + 2) {
                addMath(chars[i + 2..<end], source: chars[i..<end + 2], display: true)
                i = end + 2
                continue
            }
            if c == "$", let end = inlineMathEnd(chars, from: i) {
                addMath(chars[i + 1..<end], source: chars[i...end], display: false)
                i = end + 1
                continue
            }
            output.append(c)
            i += 1
        }
        return (output, formulas)
    }

    /// $...$ 인지 판단한다: 여는 $ 뒤와 닫는 $ 앞이 공백이 아니고, 닫는 $ 뒤가 숫자가 아니며, 한 줄 안이어야 한다 ("$5와 $10" 같은 금액 제외)
    private static func inlineMathEnd(_ chars: [Character], from start: Int) -> Int? {
        guard start + 1 < chars.count, !chars[start + 1].isWhitespace else { return nil }
        var j = start + 1
        while j < chars.count {
            let c = chars[j]
            if c.isNewline { return nil }
            if c == "\\" {
                j += 2
                continue
            }
            if c == "$" {
                if chars[j - 1].isWhitespace { return nil }
                if j + 1 < chars.count, chars[j + 1].isNumber { return nil }
                return j
            }
            j += 1
        }
        return nil
    }

    // MARK: - Markdown → 표시 글자

    private static func convert(_ parsed: AttributedString) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        var lastBlock: [Int]?
        var lastRow: Int?
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let components = run.presentationIntent?.components ?? []
            let block = components.map(\.identity)
            if block != lastBlock {
                let row = components.first { if case .tableHeaderRow = $0.kind { return true }; if case .tableRow = $0.kind { return true }; return false }?.identity
                if output.length > 0 {
                    // 같은 표 줄의 다음 칸은 탭으로, 그 밖에는 새 줄로
                    output.append(NSAttributedString(string: row != nil && row == lastRow ? "\t" : "\n", attributes: [.font: NSFont.systemFont(ofSize: bodySize)]))
                }
                if let marker = listMarker(components) {
                    output.append(NSAttributedString(string: marker, attributes: attributes(for: run, components: components)))
                }
                lastRow = row
                lastBlock = block
            }
            if components.contains(where: { if case .thematicBreak = $0.kind { return true }; return false }) {
                output.append(NSAttributedString(string: "———", attributes: [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: secondaryColor]))
                continue
            }
            var attrs = attributes(for: run, components: components)
            // 글자 그대로 쓴 주소는 파서가 뒤에 붙은 한글까지 주소로 넣으므로 detectLinks에 맡긴다
            let runText = String(parsed[run.range].characters)
            if let link = run.link, ["http", "https"].contains(link.scheme?.lowercased() ?? ""), !runText.lowercased().hasPrefix("http") {
                attrs[.link] = link
                attrs[.toolTip] = link.absoluteString   // 표시 글자와 실제 주소가 다를 수 있으니 올리면 보여 준다
            }
            // 코드 블록 끝의 줄바꿈은 블록 구분과 겹친다
            let isCodeBlock = components.contains { if case .codeBlock = $0.kind { return true }; return false }
            output.append(NSAttributedString(string: isCodeBlock && text.hasSuffix("\n") ? String(text.dropLast()) : text, attributes: attrs))
        }
        return output
    }

    private static func listMarker(_ components: [PresentationIntent.IntentType]) -> String? {
        // 첫 번째가 가장 안쪽이다
        for (index, component) in components.enumerated() {
            guard case .listItem(let ordinal) = component.kind else { continue }
            let parent = components.dropFirst(index + 1).first { if case .orderedList = $0.kind { return true }; if case .unorderedList = $0.kind { return true }; return false }
            if let parent, case .orderedList = parent.kind { return "\(ordinal). " }
            return "• "
        }
        return nil
    }

    private static func attributes(for run: AttributedString.Runs.Run, components: [PresentationIntent.IntentType]) -> [NSAttributedString.Key: Any] {
        var size = bodySize
        var bold = false
        var color = textColor
        var mono = false
        var indent: CGFloat = 0, listDepth = 0
        var table = false, header = false
        for component in components {
            switch component.kind {
            case .header(let level):
                size = level <= 1 ? 15 : (level == 2 ? 14 : 13)
                bold = true
            case .codeBlock:
                mono = true
            case .blockQuote:
                indent += 10
                color = secondaryColor
            case .unorderedList, .orderedList:
                listDepth += 1
            case .tableHeaderRow:
                table = true
                header = true
            case .tableRow:
                table = true
            default:
                break
            }
        }
        let inline = run.inlinePresentationIntent ?? []
        if inline.contains(.code) { mono = true }
        if inline.contains(.stronglyEmphasized) || header { bold = true }
        var attrs: [NSAttributedString.Key: Any] = [:]
        attrs[.font] = mono ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: bold ? .semibold : .regular)
                            : NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        attrs[.foregroundColor] = color
        // 한글 글꼴에는 기울임체가 없으므로 글자를 직접 기울인다
        if inline.contains(.emphasized) { attrs[.obliqueness] = 0.2 }
        if inline.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if mono {
            attrs[.backgroundColor] = codeBackground
            attrs[codeKey] = true
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        paragraph.lineSpacing = 1.5
        if listDepth > 0 {
            let head = CGFloat(listDepth) * 14
            paragraph.firstLineHeadIndent = head - 14 + indent
            paragraph.headIndent = head + indent
        } else if indent > 0 {
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent
        }
        if table {
            paragraph.tabStops = (1...6).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 90) }
        }
        attrs[.paragraphStyle] = paragraph
        return attrs
    }

    // MARK: - 뒤처리

    private static func applyUnderlines(_ output: NSMutableAttributedString) {
        let open = String(underlineOpen) as NSString, close = String(underlineClose) as NSString
        while true {
            let text = output.string as NSString
            let start = text.range(of: open as String)
            guard start.location != NSNotFound else { break }
            let searchStart = start.location + start.length
            let end = text.range(of: close as String, range: NSRange(location: searchStart, length: text.length - searchStart))
            if end.location == NSNotFound {
                output.deleteCharacters(in: start)
                continue
            }
            output.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                range: NSRange(location: searchStart, length: end.location - searchStart))
            output.deleteCharacters(in: end)
            output.deleteCharacters(in: start)
        }
        // 짝 없는 닫는 표식 제거
        var range = (output.string as NSString).range(of: close as String)
        while range.location != NSNotFound {
            output.deleteCharacters(in: range)
            range = (output.string as NSString).range(of: close as String)
        }
    }

    /// 글자 그대로 쓴 http(s) 주소에도 링크를 단다 (코드 안 제외)
    private static func detectLinks(_ output: NSMutableAttributedString) {
        guard let linkPattern else { return }
        let text = output.string as NSString
        for match in linkPattern.matches(in: output.string, range: NSRange(location: 0, length: text.length)) {
            let range = trimmedLink(match.range, in: text)
            guard let url = URL(string: text.substring(with: range)),
                  output.attribute(.link, at: range.location, effectiveRange: nil) == nil,
                  output.attribute(codeKey, at: range.location, effectiveRange: nil) == nil else { continue }
            output.addAttribute(.link, value: url, range: range)
            output.addAttribute(.toolTip, value: url.absoluteString, range: range)
        }
    }

    /// NSDataDetector는 언어 판별·한국어 형태소 모델까지 불러와 순간 메모리가 50MB 넘게 늘어나므로 정규식을 쓴다
    private static let linkPattern = try? NSRegularExpression(pattern: "https?://[A-Za-z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]+", options: .caseInsensitive)

    /// 문장 부호로 끝나면 주소에서 뺀다 (짝이 없는 닫는 괄호 포함)
    private static func trimmedLink(_ range: NSRange, in text: NSString) -> NSRange {
        var result = range
        while result.length > 0 {
            let last = text.substring(with: NSRange(location: result.location + result.length - 1, length: 1))
            let body = text.substring(with: result)
            let unmatched = (last == ")" && !body.contains("(")) || (last == "]" && !body.contains("["))
            guard ".,;:!?'".contains(last) || unmatched else { break }
            result.length -= 1
        }
        return result
    }

    private static func insertFormulas(_ formulas: [Math], into output: NSMutableAttributedString, maxWidth: CGFloat) {
        guard !formulas.isEmpty else { return }
        let pattern = "\(mathOpen)([0-9]+)\(mathClose)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = regex.matches(in: output.string, range: NSRange(location: 0, length: output.length))
        for match in matches.reversed() {   // 뒤에서부터 바꿔야 앞 위치가 어긋나지 않는다
            let index = Int((output.string as NSString).substring(with: match.range(at: 1))) ?? -1
            guard formulas.indices.contains(index) else { continue }
            let math = formulas[index]
            let attrs = output.attributes(at: match.range.location, effectiveRange: nil)
            let text = output.string as NSString
            let end = match.range.location + match.range.length
            let startsLine = match.range.location == 0 || text.substring(with: NSRange(location: match.range.location - 1, length: 1)) == "\n"
            let endsLine = end >= text.length || text.substring(with: NSRange(location: end, length: 1)) == "\n"
            output.replaceCharacters(in: match.range, with: formula(math, attributes: attrs, maxWidth: maxWidth, startsLine: startsLine, endsLine: endsLine))
        }
    }

    /// 별도 줄 수식은 앞뒤가 이미 줄바꿈이면 더 넣지 않는다 (빈 줄이 생기지 않게)
    private static func formula(_ math: Math, attributes: [NSAttributedString.Key: Any], maxWidth: CGFloat,
                                startsLine: Bool, endsLine: Bool) -> NSAttributedString {
        let fontSize = ((attributes[.font] as? NSFont)?.pointSize ?? bodySize) + (math.display ? 1.5 : 0.5)
        guard let rendered = MathTypesetter.render(math.latex, display: math.display, fontSize: fontSize, color: textColor, maxWidth: maxWidth) else {
            // 괄호 짝이 틀려 그릴 수 없는 수식은 원문을 한 덩어리로 보여 준다
            var attrs = attributes
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular)
            attrs[codeKey] = true
            let compact = math.latex.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return NSAttributedString(string: (math.display && !startsLine ? "\n" : "") + compact + (math.display && !endsLine ? "\n" : ""), attributes: attrs)
        }
        let attachment = MathAttachment()
        attachment.source = math.source
        attachment.image = rendered.image
        attachment.naturalBounds = CGRect(x: 0, y: -rendered.descent, width: rendered.image.size.width, height: rendered.image.size.height)
        attachment.bounds = attachment.naturalBounds
        let piece = NSMutableAttributedString(attachment: attachment)
        var attrs = attributes
        attrs.removeValue(forKey: .underlineStyle)
        if math.display {
            // 별도 줄 가운데에 놓는다
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.paragraphSpacing = 6
            paragraph.paragraphSpacingBefore = 2
            attrs[.paragraphStyle] = paragraph
            piece.addAttributes(attrs, range: NSRange(location: 0, length: piece.length))
            let result = NSMutableAttributedString(string: startsLine ? "" : "\n", attributes: attributes)
            result.append(piece)
            if !endsLine { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
            return result
        }
        piece.addAttributes(attrs, range: NSRange(location: 0, length: piece.length))
        return piece
    }

    // MARK: - 복사

    /// 선택한 부분의 글자. 수식은 그림 대신 원문으로 되돌린다.
    static func plainText(_ text: NSAttributedString, range: NSRange) -> String {
        var output = ""
        text.enumerateAttribute(.attachment, in: range) { value, subrange, _ in
            if let math = value as? MathAttachment {
                output += math.source
            } else {
                output += (text.string as NSString).substring(with: subrange)
            }
        }
        return output
    }
}
