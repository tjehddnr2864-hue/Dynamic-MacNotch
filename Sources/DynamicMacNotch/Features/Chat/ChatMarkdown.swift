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
            if c == "<", let end = htmlTagEnd(chars, from: i) {
                // 노치에 맞지 않는 HTML 태그는 걷어 낸다 (줄바꿈만 살린다)
                if String(chars[i...end]).lowercased().hasPrefix("<br") { output.append("\n") }
                i = end + 1
                continue
            }
            if starts("[^", at: i), let close = chars[i...].prefix(40).firstIndex(of: "]"), close > i + 2 {
                // 각주 표기는 그대로 보이므로 (1)처럼 바꾼다
                output += "(" + String(chars[i + 2..<close]) + ")"
                i = close + 1
                if i < chars.count, chars[i] == ":" { i += 1 }
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

    private static let htmlTag = try? NSRegularExpression(
        pattern: "^</?(b|i|u|s|em|strong|span|div|p|br|sub|sup|small|a|font|code|pre|hr|ul|ol|li|table|thead|tbody|tr|td|th|img|h[1-6]|details|summary|mark|kbd|del|center|blockquote)(\\s+[a-zA-Z-]+=(\"[^\"]*\"|'[^']*'))*\\s*/?>",
        options: .caseInsensitive)

    /// 알려진 HTML 태그이면 닫는 >의 위치 (a<b and c>d 같은 글은 태그가 아니다)
    private static func htmlTagEnd(_ chars: [Character], from start: Int) -> Int? {
        let tail = String(chars[start..<min(start + 200, chars.count)])
        guard let match = htmlTag?.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)),
              let range = Range(match.range, in: tail) else { return nil }
        return start + tail[range].count - 1
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
        var table: TableBuilder?
        func flushTable() {
            guard let finished = table else { return }
            table = nil
            finished.append(to: output)
        }
        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            let components = run.presentationIntent?.components ?? []
            let block = components.map(\.identity)
            let tableKind = components.compactMap { component -> (id: Int, columns: Int)? in
                if case .table(let columns) = component.kind { return (component.identity, columns.count) }
                return nil
            }.first
            var attrs = attributes(for: run, components: components)
            // 글자 그대로 쓴 주소는 파서가 뒤에 붙은 한글까지 주소로 넣으므로 detectLinks에 맡긴다
            if let link = run.link, ["http", "https"].contains(link.scheme?.lowercased() ?? ""), !text.lowercased().hasPrefix("http") {
                attrs[.link] = link
                attrs[.toolTip] = link.absoluteString   // 표시 글자와 실제 주소가 다를 수 있으니 올리면 보여 준다
            }
            if let tableKind {
                if table?.id != tableKind.id {
                    flushTable()
                    table = TableBuilder(id: tableKind.id, columns: tableKind.columns)
                }
                table?.add(text, attributes: attrs, components: components)
                lastBlock = block
                continue
            }
            flushTable()
            // 수평선은 공간만 차지하므로 그리지 않는다
            if components.contains(where: { if case .thematicBreak = $0.kind { return true }; return false }) {
                lastBlock = block
                continue
            }
            if block != lastBlock {
                if output.length > 0, !output.string.hasSuffix("\n") {
                    output.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: bodySize)]))
                }
                if let marker = listMarker(components) {
                    output.append(NSAttributedString(string: marker, attributes: attrs.filter { $0.key != .link && $0.key != .toolTip }))
                    // 체크박스 표기는 그대로 보이므로 기호로 바꾼다
                    if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) }
                    else if text.lowercased().hasPrefix("[x] ") { text = "☑ " + text.dropFirst(4) }
                }
                lastBlock = block
            }
            // 코드 블록 끝의 줄바꿈은 블록 구분과 겹친다
            let isCodeBlock = components.contains { if case .codeBlock = $0.kind { return true }; return false }
            output.append(NSAttributedString(string: isCodeBlock && text.hasSuffix("\n") ? String(text.dropLast()) : text, attributes: attrs))
        }
        flushTable()
        return output
    }

    /// 표. 3열 이하는 폭에 맞춰 칸을 나눠 그리고, 그보다 넓으면 노치에서 읽을 수 없으므로 항목 목록으로 바꾼다.
    private final class TableBuilder {
        let id: Int
        let columns: Int
        private var headers: [NSMutableAttributedString] = []
        private var rows: [[NSMutableAttributedString]] = []
        private var currentRow: Int?

        init(id: Int, columns: Int) {
            self.id = id
            self.columns = columns
        }

        func add(_ text: String, attributes: [NSAttributedString.Key: Any], components: [PresentationIntent.IntentType]) {
            var column = 0, isHeader = false, rowID = -1
            for component in components {
                switch component.kind {
                case .tableCell(let index): column = index
                case .tableHeaderRow:
                    isHeader = true
                    rowID = component.identity
                case .tableRow:
                    rowID = component.identity
                default: break
                }
            }
            func put(_ cells: inout [NSMutableAttributedString]) {
                while cells.count <= column { cells.append(NSMutableAttributedString()) }
                cells[column].append(NSAttributedString(string: text, attributes: attributes))
            }
            if isHeader {
                put(&headers)
            } else {
                if currentRow != rowID {
                    currentRow = rowID
                    rows.append([])
                }
                put(&rows[rows.count - 1])
            }
        }

        func append(to output: NSMutableAttributedString) {
            if output.length > 0, !output.string.hasSuffix("\n") {
                output.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: ChatMarkdown.bodySize)]))
            }
            if columns <= 3 { appendGrid(to: output) } else { appendRecords(to: output) }
        }

        private func appendGrid(to output: NSMutableAttributedString) {
            let table = NSTextTable()
            table.numberOfColumns = columns
            table.layoutAlgorithm = .fixedLayoutAlgorithm
            table.setContentWidth(100, type: .percentageValueType)
            table.hidesEmptyCells = false
            let line = NSColor.white.withAlphaComponent(0.22)
            for (r, row) in ([headers] + rows).enumerated() {
                for c in 0..<columns {
                    let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                    block.setContentWidth(100 / CGFloat(columns), type: .percentageValueType)
                    block.setWidth(3, type: .absoluteValueType, for: .padding)
                    block.setWidth(0.5, type: .absoluteValueType, for: .border)
                    block.setBorderColor(line)
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.textBlocks = [block]
                    paragraph.lineSpacing = 1.5
                    let cell = NSMutableAttributedString(attributedString: c < row.count ? row[c] : NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: ChatMarkdown.bodySize)]))
                    cell.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: ChatMarkdown.bodySize)]))
                    cell.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cell.length))
                    output.append(cell)
                }
            }
        }

        private func appendRecords(to output: NSMutableAttributedString) {
            let font = NSFont.systemFont(ofSize: ChatMarkdown.bodySize)
            let heading = NSMutableParagraphStyle()
            heading.paragraphSpacing = 2
            heading.paragraphSpacingBefore = 4
            let detail = NSMutableParagraphStyle()
            detail.firstLineHeadIndent = 10
            detail.headIndent = 10
            detail.paragraphSpacing = 1
            for row in rows {
                guard let first = row.first else { continue }
                let title = NSMutableAttributedString(attributedString: first)
                title.addAttribute(.font, value: NSFont.systemFont(ofSize: ChatMarkdown.bodySize, weight: .semibold), range: NSRange(location: 0, length: title.length))
                title.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                title.addAttribute(.paragraphStyle, value: heading, range: NSRange(location: 0, length: title.length))
                output.append(title)
                for (c, cell) in row.enumerated().dropFirst() where cell.length > 0 {
                    let line = NSMutableAttributedString()
                    if c < headers.count, headers[c].length > 0 {
                        line.append(NSAttributedString(string: headers[c].string + ": ", attributes: [.font: font, .foregroundColor: ChatMarkdown.secondaryColor]))
                    }
                    line.append(cell)
                    line.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                    line.addAttribute(.paragraphStyle, value: detail, range: NSRange(location: 0, length: line.length))
                    output.append(line)
                }
            }
        }
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
        let size = bodySize
        var bold = false
        var color = textColor
        var mono = false
        var indent: CGFloat = 0, listDepth = 0
        var header = false
        for component in components {
            switch component.kind {
            case .header:
                bold = true   // 제목은 세로 공간을 아끼려고 본문 크기의 굵은 글씨로 그린다
            case .codeBlock:
                mono = true
            case .blockQuote:
                indent += 10
                color = secondaryColor
            case .unorderedList, .orderedList:
                listDepth += 1
            case .tableHeaderRow:
                header = true
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
            func extra(_ close: Character, _ open: Character) -> Bool { body.filter { $0 == close }.count > body.filter { $0 == open }.count }
            let unmatched = (last == ")" && extra(")", "(")) || (last == "]" && extra("]", "["))
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
