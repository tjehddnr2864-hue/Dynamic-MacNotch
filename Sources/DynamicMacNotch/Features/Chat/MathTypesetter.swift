import AppKit
import CoreText

/// AI 채팅의 LaTeX 수식을 그린다. macOS 내장 수학 글꼴(STIX Two Math)과 CoreText만 쓴다 (WebKit·외부 라이브러리 없음).
/// 모르는 명령은 그 이름을 글자로 두고 나머지를 그린다. 괄호 짝이 틀린 수식만 nil을 돌려준다 (호출한 쪽이 원문을 보여 준다).
enum MathTypesetter {
    struct Rendered {
        let image: NSImage
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// maxWidth를 넘으면 그 폭에 맞게 줄인다
    static func render(_ latex: String, display: Bool, fontSize: CGFloat, color: NSColor, maxWidth: CGFloat) -> Rendered? {
        var parser = Parser(latex)
        guard let atoms = try? parser.parseAll() else { return nil }
        let style = Style(size: fontSize, display: display, base: fontSize)
        let box = display ? wrapped(atoms, style, maxWidth: maxWidth) : layout(atoms, style)
        guard box.width > 0 else { return nil }
        let scale = min(1, maxWidth / box.width)
        let pad: CGFloat = 1
        let size = NSSize(width: ceil(box.width * scale) + pad * 2, height: ceil((box.ascent + box.descent) * scale) + pad * 2)
        let baseline = box.descent * scale + pad
        let cgColor = color.cgColor
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(cgColor)
            ctx.setStrokeColor(cgColor)
            ctx.translateBy(x: pad, y: baseline)
            ctx.scaleBy(x: scale, y: scale)
            box.draw(ctx, .zero)
            return true
        }
        return Rendered(image: image, ascent: box.ascent * scale + pad, descent: box.descent * scale + pad)
    }

    // MARK: - 구문

    fileprivate indirect enum Atom {
        case symbol(String, Kind)
        case text(String)
        case space(CGFloat)     // em 단위
        case group([Atom])
        case scripts(base: Atom, sup: [Atom]?, sub: [Atom]?)
        case bigOp(String, limits: Bool)
        case function(String, limits: Bool)
        case frac([Atom], [Atom], line: Bool)
        case sqrt([Atom], index: [Atom]?)
        case accent(String, [Atom])
        case overline([Atom])
        case underline([Atom])
        case boxed([Atom])
        case over(base: [Atom], top: [Atom]?, bottom: [Atom]?)
        case delimited(String, [Atom], String)
        case bigDelim(String, CGFloat)
        case grid([[[Atom]]], alignment: GridAlignment, left: String, right: String)
    }

    fileprivate enum Kind { case ord, op, bin, rel, open, close, punct }
    fileprivate enum GridAlignment { case center, left, rightLeft }
    private struct Unsupported: Error {}

    private struct Parser {
        private let chars: [Character]
        private var pos = 0

        init(_ source: String) { chars = Array(source) }

        mutating func parseAll() throws -> [Atom] {
            let atoms = try parseList(stopAtBrace: false, stopCommands: [])
            guard pos >= chars.count else { throw Unsupported() }
            return atoms
        }

        private var peek: Character? { pos < chars.count ? chars[pos] : nil }

        private mutating func skipSpaces() {
            while let c = peek, c.isWhitespace { pos += 1 }
        }

        private mutating func readCommand() -> String {
            pos += 1   // 역슬래시
            guard let first = peek else { return "" }
            guard first.isLetter else {
                pos += 1
                return String(first)
            }
            var name = ""
            while let c = peek, c.isLetter {
                name.append(c)
                pos += 1
            }
            return name
        }

        private func peekCommand() -> String? {
            guard peek == "\\", pos + 1 < chars.count else { return nil }
            var i = pos + 1
            guard chars[i].isLetter else { return String(chars[i]) }
            var name = ""
            while i < chars.count, chars[i].isLetter {
                name.append(chars[i])
                i += 1
            }
            return name
        }

        /// stopCommands(\right, \end, 행 구분 등) 또는 '}'·'&'에서 멈춘다 (소비하지 않음)
        private mutating func parseList(stopAtBrace: Bool, stopCommands: Set<String>, stopAtAmpersand: Bool = false) throws -> [Atom] {
            var atoms: [Atom] = []
            while true {
                skipSpaces()
                guard let c = peek else {
                    if stopAtBrace { throw Unsupported() }
                    return atoms
                }
                if c == "}" {
                    if stopAtBrace { return atoms }
                    throw Unsupported()
                }
                if c == "&" {
                    if stopAtAmpersand { return atoms }
                    throw Unsupported()
                }
                if let name = peekCommand(), stopCommands.contains(name) { return atoms }
                if c == "^" || c == "_" {
                    pos += 1
                    let script = try parseArgument()
                    let last = atoms.popLast() ?? .group([])
                    atoms.append(attach(script, isSup: c == "^", to: last))
                    continue
                }
                if c == "'" {
                    pos += 1
                    let last = atoms.popLast() ?? .group([])
                    atoms.append(attach([.symbol("′", .ord)], isSup: true, to: last))
                    continue
                }
                atoms.append(try parseAtom())
            }
        }

        private func attach(_ script: [Atom], isSup: Bool, to base: Atom) -> Atom {
            if case .scripts(let b, let sup, let sub) = base {
                if isSup, sup == nil { return .scripts(base: b, sup: script, sub: sub) }
                if !isSup, sub == nil { return .scripts(base: b, sup: sup, sub: script) }
            }
            return .scripts(base: base, sup: isSup ? script : nil, sub: isSup ? nil : script)
        }

        /// {묶음} 또는 글자·명령 하나
        private mutating func parseArgument() throws -> [Atom] {
            skipSpaces()
            guard let c = peek else { throw Unsupported() }
            if c == "{" {
                pos += 1
                let atoms = try parseList(stopAtBrace: true, stopCommands: [])
                pos += 1
                return atoms
            }
            return [try parseAtom()]
        }

        /// {글자} 그대로 읽기 (\text 등)
        private mutating func parseRawGroup() throws -> String {
            skipSpaces()
            guard peek == "{" else { throw Unsupported() }
            pos += 1
            var depth = 1, text = ""
            while let c = peek {
                pos += 1
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { return text }
                }
                text.append(c)
            }
            throw Unsupported()
        }

        private mutating func parseDelimiter() throws -> String {
            skipSpaces()
            guard let c = peek else { throw Unsupported() }
            if c == "\\" {
                let name = readCommand()
                if let symbol = Symbols.delimiters[name] { return symbol }
                throw Unsupported()
            }
            pos += 1
            return c == "." ? "" : String(c)
        }

        private mutating func parseAtom() throws -> Atom {
            guard let c = peek else { throw Unsupported() }
            if c == "{" {
                pos += 1
                let atoms = try parseList(stopAtBrace: true, stopCommands: [])
                pos += 1
                return .group(atoms)
            }
            if c == "\\" { return try parseCommand(readCommand()) }
            pos += 1
            return Symbols.character(c)
        }

        private mutating func parseCommand(_ name: String) throws -> Atom {
            if let (symbol, kind) = Symbols.table[name] { return .symbol(symbol, kind) }
            if let symbol = Symbols.bigOps[name] { return .bigOp(symbol, limits: !name.contains("int")) }
            if Symbols.functions.contains(name) { return .function(name, limits: Symbols.limitFunctions.contains(name)) }
            if let em = Symbols.spaces[name] { return .space(em) }
            if let accent = Symbols.accents[name] { return .accent(accent, try parseArgument()) }
            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let n = try parseArgument()
                return .frac(n, try parseArgument(), line: true)
            case "binom":
                let n = try parseArgument()
                return .delimited("(", [.frac(n, try parseArgument(), line: false)], ")")
            case "sqrt":
                skipSpaces()
                var index: [Atom]?
                if peek == "[" {
                    pos += 1
                    var raw = ""
                    while let c = peek, c != "]" {
                        raw.append(c)
                        pos += 1
                    }
                    pos += 1
                    var inner = Parser(raw)
                    index = try inner.parseAll()
                }
                return .sqrt(try parseArgument(), index: index)
            case "text", "mathrm", "textrm", "operatorname", "mbox", "textit":
                return .text(try parseRawGroup())
            case "mathbf", "textbf", "boldsymbol", "bm":
                return Symbols.styled(try parseRawGroup(), upper: 0x1D400, lower: 0x1D41A)
            case "mathit":
                return .group(try parseArgument())
            case "mathbb":
                return Symbols.doubleStruck(try parseRawGroup())
            case "mathcal":
                return Symbols.styled(try parseRawGroup(), upper: 0x1D49C, lower: 0x1D4B6)
            case "overline":
                return .overline(try parseArgument())
            case "underline":
                return .underline(try parseArgument())
            case "boxed", "fbox":
                return .boxed(try parseArgument())
            case "overset", "stackrel":
                let top = try parseArgument()
                return .over(base: try parseArgument(), top: top, bottom: nil)
            case "underset":
                let bottom = try parseArgument()
                return .over(base: try parseArgument(), top: nil, bottom: bottom)
            case "underbrace", "overbrace", "cancel", "bcancel", "xcancel", "mathsf", "mathtt", "mathfrak", "mathscr", "mathnormal", "pmb", "ensuremath":
                return .group(try parseArgument())
            case "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "limits", "nolimits", "nonumber", "notag", "hline", "centering", "allowbreak", "nobreak":
                return .group([])
            case "color":
                _ = try parseRawGroup()
                return .group([])
            case "textcolor":
                _ = try parseRawGroup()
                return .group(try parseArgument())
            case "hspace", "vspace", "phantom", "hphantom", "vphantom":
                _ = try parseRawGroup()
                return .space(name == "hspace" ? 0.5 : 0)
            case "tag":
                return .group([.space(1), .text("(" + (try parseRawGroup()) + ")")])
            case "pmod":
                let inner = try parseArgument()
                return .group([.space(0.5), .symbol("(", .open), .function("mod", limits: false), .space(0.17), .group(inner), .symbol(")", .close)])
            case "substack":
                skipSpaces()
                guard peek == "{" else { throw Unsupported() }
                pos += 1
                var rows: [[[Atom]]] = []
                while true {
                    rows.append([try parseList(stopAtBrace: true, stopCommands: ["\\"])])
                    guard peekCommand() == "\\" else { break }
                    _ = readCommand()
                }
                pos += 1
                return .grid(rows, alignment: .center, left: "", right: "")
            case "not":
                skipSpaces()
                if peek == "=" {
                    pos += 1
                    return .symbol("≠", .rel)
                }
                if case .symbol(let text, let kind) = try parseAtom() { return .symbol(text + "\u{0338}", kind) }
                return .group([])
            case "\\":   // 환경 밖의 줄바꿈은 넓은 띄어쓰기로
                return .space(1)
            case "left":
                let open = try parseDelimiter()
                let inner = try parseList(stopAtBrace: false, stopCommands: ["right"])
                guard peekCommand() == "right" else { throw Unsupported() }
                _ = readCommand()
                return .delimited(open, inner, try parseDelimiter())
            case "big", "bigl", "bigr", "bigm": return .bigDelim(try parseDelimiter(), 1.2)
            case "Big", "Bigl", "Bigr", "Bigm": return .bigDelim(try parseDelimiter(), 1.6)
            case "bigg", "biggl", "biggr", "biggm": return .bigDelim(try parseDelimiter(), 2.1)
            case "Bigg", "Biggl", "Biggr", "Biggm": return .bigDelim(try parseDelimiter(), 2.6)
            case "begin":
                return try parseEnvironment(try parseRawGroup())
            default:
                // 모르는 명령 하나 때문에 수식 전체가 풀어지지 않게, 이름만 글자로 둔다
                return .text(name)
            }
        }

        private mutating func parseEnvironment(_ name: String) throws -> Atom {
            let style: (GridAlignment, String, String)
            let base = name.replacingOccurrences(of: "*", with: "")
            // {cc} 같은 열 지정은 건너뛴다
            if base == "array" || base == "alignedat" || base == "alignat" { _ = try parseRawGroup() }
            switch base {
            case "matrix", "smallmatrix", "array": style = (.center, "", "")
            case "rcases": style = (.left, "", "}")
            case "pmatrix": style = (.center, "(", ")")
            case "bmatrix": style = (.center, "[", "]")
            case "Bmatrix": style = (.center, "{", "}")
            case "vmatrix": style = (.center, "|", "|")
            case "Vmatrix": style = (.center, "‖", "‖")
            case "cases", "dcases": style = (.left, "{", "")
            case "gathered", "gather", "multline": style = (.center, "", "")
            case "aligned", "align", "split", "alignedat", "alignat", "eqnarray", "flalign": style = (.rightLeft, "", "")
            default: throw Unsupported()
            }
            var rows: [[[Atom]]] = [[]]
            while true {
                let cell = try parseList(stopAtBrace: false, stopCommands: ["\\", "end"], stopAtAmpersand: true)
                rows[rows.count - 1].append(cell)
                skipSpaces()
                if peek == "&" {
                    pos += 1
                    continue
                }
                let command = peekCommand()
                guard let command else { throw Unsupported() }
                _ = readCommand()
                if command == "\\" {
                    rows.append([])
                    continue
                }
                _ = try parseRawGroup()   // \end{...}
                break
            }
            // 줄 끝의 \\ 뒤에 생긴 빈 줄은 뺀다
            if let last = rows.last, last.count == 1, last[0].isEmpty { rows.removeLast() }
            return .grid(rows, alignment: style.0, left: style.1, right: style.2)
        }
    }

    // MARK: - 기호

    private enum Symbols {
        static let table: [String: (String, Kind)] = {
            var t: [String: (String, Kind)] = [:]
            let greek = ["alpha": "𝛼", "beta": "𝛽", "gamma": "𝛾", "delta": "𝛿", "epsilon": "𝜖", "varepsilon": "𝜀", "zeta": "𝜁", "eta": "𝜂",
                         "theta": "𝜃", "vartheta": "𝜗", "iota": "𝜄", "kappa": "𝜅", "lambda": "𝜆", "mu": "𝜇", "nu": "𝜈", "xi": "𝜉", "pi": "𝜋",
                         "varpi": "𝜛", "rho": "𝜌", "varrho": "𝜚", "sigma": "𝜎", "varsigma": "𝜍", "tau": "𝜏", "upsilon": "𝜐", "phi": "𝜙",
                         "varphi": "𝜑", "chi": "𝜒", "psi": "𝜓", "omega": "𝜔", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
                         "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω"]
            for (k, v) in greek { t[k] = (v, .ord) }
            let ord = ["infty": "∞", "partial": "∂", "nabla": "∇", "forall": "∀", "exists": "∃", "nexists": "∄", "emptyset": "∅", "varnothing": "∅",
                       "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "ell": "ℓ", "hbar": "ℏ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ",
                       "prime": "′", "angle": "∠", "triangle": "△", "neg": "¬", "lnot": "¬", "degree": "°", "%": "%", "$": "$", "#": "#", "&": "&", "_": "_",
                       "checkmark": "✓", "circ": "∘", "bullet": "•", "star": "⋆", "dagger": "†"]
            for (k, v) in ord { t[k] = (v, .ord) }
            let bin = ["times": "×", "cdot": "⋅", "div": "÷", "pm": "±", "mp": "∓", "cup": "∪", "cap": "∩", "setminus": "∖", "wedge": "∧", "land": "∧",
                       "vee": "∨", "lor": "∨", "oplus": "⊕", "otimes": "⊗", "ast": "∗"]
            for (k, v) in bin { t[k] = (v, .bin) }
            let more = ["therefore": "∴", "because": "∵", "top": "⊤", "bot": "⊥", "dotsc": "…", "dotsb": "⋯", "dotsm": "⋯", "dotsi": "⋯", "ldotp": ".", "cdotp": "⋅",
                        "wp": "℘", "mho": "℧", "complement": "∁", "square": "□", "Box": "□", "blacksquare": "■", "diamond": "⋄", "lozenge": "◊", "sharp": "♯", "flat": "♭",
                        "S": "§", "P": "¶", "pounds": "£", "textbackslash": "\\", "backslash": "\\", "colon": ":", "lvert": "|", "rvert": "|", "lVert": "‖", "rVert": "‖", "vert": "|", "Vert": "‖"]
            for (k, v) in more { t[k] = (v, .ord) }
            let moreBin = ["bmod": "mod", "uplus": "⊎", "sqcup": "⊔", "sqcap": "⊓", "odot": "⊙", "ominus": "⊖", "oslash": "⊘", "dotplus": "∔", "ltimes": "⋉", "rtimes": "⋊", "bigcirc": "◯", "amalg": "⨿"]
            for (k, v) in moreBin { t[k] = (v, .bin) }
            let moreRel = ["Longrightarrow": "⟹", "Longleftarrow": "⟸", "Longleftrightarrow": "⟺", "longrightarrow": "⟶", "longleftarrow": "⟵", "longleftrightarrow": "⟷",
                           "longmapsto": "⟼", "hookrightarrow": "↪", "hookleftarrow": "↩", "rightharpoonup": "⇀", "leftharpoonup": "↼", "rightleftharpoons": "⇌", "nearrow": "↗", "searrow": "↘",
                           "swarrow": "↙", "nwarrow": "↖", "Uparrow": "⇑", "Downarrow": "⇓", "updownarrow": "↕", "nrightarrow": "↛", "nleftarrow": "↚", "nRightarrow": "⇏", "rightsquigarrow": "⇝",
                           "leqslant": "⩽", "geqslant": "⩾", "nleq": "≰", "ngeq": "≱", "nless": "≮", "ngtr": "≯", "lesssim": "≲", "gtrsim": "≳", "prec": "≺", "succ": "≻", "preceq": "⪯", "succeq": "⪰",
                           "doteq": "≐", "triangleq": "≜", "coloneqq": "≔", "eqqcolon": "≕", "asymp": "≍", "nsim": "≁", "ncong": "≇", "models": "⊨", "vdash": "⊢", "dashv": "⊣", "nmid": "∤", "nparallel": "∦",
                           "subsetneq": "⊊", "supsetneq": "⊋", "nsubseteq": "⊈", "nsupseteq": "⊉", "sqsubseteq": "⊑", "sqsupseteq": "⊒", "bowtie": "⋈", "approxeq": "≊"]
            for (k, v) in moreRel { t[k] = (v, .rel) }
            let rel = ["leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "sim": "∼", "simeq": "≃", "cong": "≅", "equiv": "≡",
                       "propto": "∝", "ll": "≪", "gg": "≫", "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
                       "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐",
                       "Leftrightarrow": "⇔", "implies": "⇒", "iff": "⇔", "mapsto": "↦", "uparrow": "↑", "downarrow": "↓", "perp": "⊥", "parallel": "∥", "mid": "∣"]
            for (k, v) in rel { t[k] = (v, .rel) }
            t["{"] = ("{", .open)
            t["}"] = ("}", .close)
            t["langle"] = ("⟨", .open)
            t["rangle"] = ("⟩", .close)
            t["lfloor"] = ("⌊", .open)
            t["rfloor"] = ("⌋", .close)
            t["lceil"] = ("⌈", .open)
            t["rceil"] = ("⌉", .close)
            t["|"] = ("‖", .ord)
            return t
        }()

        static let delimiters: [String: String] = ["{": "{", "}": "}", "|": "‖", "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋",
                                                   "lceil": "⌈", "rceil": "⌉", "lbrace": "{", "rbrace": "}", "vert": "|", "Vert": "‖"]
        static let bigOps = ["sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
                             "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂"]
        static let functions: Set<String> = ["sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "log", "ln", "lg", "exp",
                                             "lim", "max", "min", "sup", "inf", "det", "gcd", "deg", "dim", "ker", "arg", "Pr", "mod"]
        static let limitFunctions: Set<String> = ["lim", "max", "min", "sup", "inf", "det", "gcd", "Pr"]
        static let spaces: [String: CGFloat] = [",": 0.167, ":": 0.222, ";": 0.278, "!": -0.167, " ": 0.25, "quad": 1, "qquad": 2]
        static let accents = ["hat": "ˆ", "widehat": "ˆ", "bar": "¯", "vec": "→", "tilde": "˜", "widetilde": "˜", "dot": "˙", "ddot": "¨"]

        static func character(_ c: Character) -> Atom {
            if let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 {
                let v = scalar.value
                if v >= 0x61, v <= 0x7A {   // 변수는 수학 기울임체
                    return .symbol(v == 0x68 ? "ℎ" : String(UnicodeScalar(0x1D44E + v - 0x61)!), .ord)
                }
                if v >= 0x41, v <= 0x5A { return .symbol(String(UnicodeScalar(0x1D434 + v - 0x41)!), .ord) }
            }
            switch c {
            case "+", "*", "/": return .symbol(c == "*" ? "∗" : String(c), c == "/" ? .ord : .bin)
            case "-": return .symbol("−", .bin)
            case "=", "<", ">", ":": return .symbol(String(c), .rel)
            case "(", "[": return .symbol(String(c), .open)
            case ")", "]": return .symbol(String(c), .close)
            case ",", ";": return .symbol(String(c), .punct)
            default: return .symbol(String(c), .ord)
            }
        }

        static func styled(_ text: String, upper: UInt32, lower: UInt32) -> Atom {
            .group(text.map { c -> Atom in
                guard let v = c.unicodeScalars.first?.value else { return .symbol(String(c), .ord) }
                if v >= 0x41, v <= 0x5A, let s = UnicodeScalar(upper + v - 0x41) { return .symbol(String(s), .ord) }
                if v >= 0x61, v <= 0x7A, let s = UnicodeScalar(lower + v - 0x61) { return .symbol(String(s), .ord) }
                return .symbol(String(c), .ord)
            })
        }

        static func doubleStruck(_ text: String) -> Atom {
            let special: [Character: String] = ["C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ"]
            return .group(text.map { c -> Atom in
                if let s = special[c] { return .symbol(s, .ord) }
                guard let v = c.unicodeScalars.first?.value, v >= 0x41, v <= 0x5A, let s = UnicodeScalar(0x1D538 + v - 0x41) else { return .symbol(String(c), .ord) }
                return .symbol(String(s), .ord)
            })
        }
    }

    // MARK: - 배치

    private struct Style {
        var size: CGFloat
        var display: Bool
        var base: CGFloat
        var script: Style { Style(size: max(size * 0.72, base * 0.6), display: false, base: base) }
        var axis: CGFloat { size * 0.25 }
    }

    private final class Box {
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var kind: Kind = .ord
        let draw: (CGContext, CGPoint) -> Void
        init(width: CGFloat, ascent: CGFloat, descent: CGFloat, draw: @escaping (CGContext, CGPoint) -> Void) {
            self.width = width
            self.ascent = ascent
            self.descent = descent
            self.draw = draw
        }
    }

    /// 수식마다 글꼴을 새로 만들지 않고 크기별로 재사용한다 (시스템의 글자 캐시가 덜 늘어난다)
    private static let mathFonts = NSCache<NSNumber, CTFont>()

    private static func mathFont(_ size: CGFloat) -> CTFont {
        let key = NSNumber(value: Double(size))
        if let font = mathFonts.object(forKey: key) { return font }
        let font = CTFontCreateWithName("STIXTwoMath-Regular" as CFString, size, nil)
        mathFonts.setObject(font, forKey: key)
        return font
    }

    private static func glyphs(_ text: String, font: CTFont) -> Box {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return Box(width: CGFloat(width), ascent: max(bounds.maxY, 0), descent: max(-bounds.minY, 0)) { ctx, origin in
            ctx.textMatrix = .identity
            ctx.textPosition = origin
            CTLineDraw(line, ctx)
        }
    }

    private static func symbolBox(_ text: String, _ style: Style) -> Box { glyphs(text, font: mathFont(style.size)) }

    private static func stack(_ boxes: [Box]) -> Box {
        let width = boxes.reduce(0) { $0 + $1.width }
        return Box(width: width, ascent: boxes.map(\.ascent).max() ?? 0, descent: boxes.map(\.descent).max() ?? 0) { ctx, origin in
            var x = origin.x
            for box in boxes {
                box.draw(ctx, CGPoint(x: x, y: origin.y))
                x += box.width
            }
        }
    }

    private static func spacer(_ width: CGFloat) -> Box { Box(width: width, ascent: 0, descent: 0) { _, _ in } }

    /// 별도 줄 수식이 칸보다 넓으면 관계 기호(=, ⇒ 등) 앞에서 줄을 바꾼다. 그래도 넓은 줄은 호출한 쪽이 줄인다.
    private static func wrapped(_ atoms: [Atom], _ style: Style, maxWidth: CGFloat) -> Box {
        let whole = layout(atoms, style)
        guard whole.width > maxWidth else { return whole }
        var pieces: [[Atom]] = [[]]
        for atom in atoms {
            if case .symbol(_, .rel) = atom, !pieces[pieces.count - 1].isEmpty { pieces.append([]) }
            pieces[pieces.count - 1].append(atom)
        }
        guard pieces.count > 1 else { return whole }
        var lines: [[Atom]] = []
        for piece in pieces {
            if let last = lines.last, layout(last + piece, style).width <= maxWidth {
                lines[lines.count - 1] += piece
            } else {
                lines.append(piece)
            }
        }
        // 줄 앞뒤의 띄어쓰기(\\quad 등)는 뺀다
        let boxes = lines.map { line -> Box in
            var line = line
            while case .space = line.first { line.removeFirst() }
            while case .space = line.last { line.removeLast() }
            return layout(line, style)
        }
        let gap = style.size * 0.3
        let width = boxes.map(\.width).max() ?? 0
        let height = boxes.reduce(0) { $0 + $1.ascent + $1.descent } + gap * CGFloat(boxes.count - 1)
        let ascent = boxes.first?.ascent ?? 0
        return Box(width: width, ascent: ascent, descent: height - ascent) { ctx, origin in
            var y = origin.y
            for box in boxes {
                box.draw(ctx, CGPoint(x: origin.x, y: y))
                y -= box.descent + gap
                if let next = boxes.dropFirst(boxes.firstIndex { $0 === box }! + 1).first { y -= next.ascent }
            }
        }
    }

    private static func layout(_ atoms: [Atom], _ style: Style) -> Box {
        var boxes: [Box] = []
        var previous: Kind?
        let spaced = style.size >= style.base * 0.95
        for atom in atoms {
            if case .space(let em) = atom {
                boxes.append(spacer(em * style.size))
                continue
            }
            let box = layout(atom, style)
            var kind = box.kind
            // 맨 앞이나 여는 기호·연산자 뒤의 '-', '+'는 부호로 본다
            if kind == .bin, previous == nil || previous == .bin || previous == .rel || previous == .open || previous == .punct { kind = .ord }
            if let previous, spaced {
                var em: CGFloat = 0
                if kind == .rel || previous == .rel { em = 0.28 }
                else if kind == .bin || previous == .bin { em = 0.22 }
                else if previous == .punct { em = 0.17 }
                else if previous == .op, kind != .open, kind != .close { em = 0.17 }   // sin x (괄호가 바로 오면 붙인다)
                else if kind == .op, previous != .open { em = 0.17 }
                if em > 0 { boxes.append(spacer(em * style.size)) }
            }
            boxes.append(box)
            previous = kind
        }
        return stack(boxes)
    }

    private static func layout(_ atom: Atom, _ style: Style) -> Box {
        switch atom {
        case .symbol(let text, let kind):
            let box = symbolBox(text, style)
            box.kind = kind
            return box
        case .text(let text):
            return glyphs(text, font: NSFont.systemFont(ofSize: style.size))
        case .space(let em):
            return spacer(em * style.size)
        case .group(let atoms):
            return layout(atoms, style)
        case .scripts(let base, let sup, let sub):
            return scripts(base: base, sup: sup, sub: sub, style)
        case .bigOp(let symbol, _):
            let box = bigOperator(symbol, style)
            box.kind = .op
            return box
        case .function(let name, _):
            let box = glyphs(name, font: NSFont.systemFont(ofSize: style.size))
            box.kind = .op
            return box
        case .frac(let numerator, let denominator, let line):
            return fraction(numerator, denominator, line: line, style)
        case .sqrt(let inner, let index):
            return radical(inner, index: index, style)
        case .accent(let mark, let inner):
            return accent(mark, inner, style)
        case .underline(let inner):
            let box = layout(inner, style)
            let gap = style.size * 0.1, thickness = max(style.size * 0.05, 0.6)
            return Box(width: box.width, ascent: box.ascent, descent: box.descent + gap + thickness) { ctx, origin in
                box.draw(ctx, origin)
                ctx.fill(CGRect(x: origin.x, y: origin.y - box.descent - gap - thickness, width: box.width, height: thickness))
            }
        case .boxed(let inner):
            let box = layout(inner, style)
            let pad = style.size * 0.25, thickness = max(style.size * 0.05, 0.6)
            return Box(width: box.width + (pad + thickness) * 2, ascent: box.ascent + pad + thickness, descent: box.descent + pad + thickness) { ctx, origin in
                box.draw(ctx, CGPoint(x: origin.x + pad + thickness, y: origin.y))
                ctx.setLineWidth(thickness)
                ctx.stroke(CGRect(x: origin.x + thickness / 2, y: origin.y - box.descent - pad - thickness / 2,
                                  width: box.width + pad * 2 + thickness, height: box.ascent + box.descent + pad * 2 + thickness))
            }
        case .over(let base, let top, let bottom):
            return scripts(base: .group(base), sup: top, sub: bottom, style, forceLimits: true)
        case .overline(let inner):
            let box = layout(inner, style)
            let gap = style.size * 0.12, thickness = max(style.size * 0.05, 0.6)
            return Box(width: box.width, ascent: box.ascent + gap + thickness, descent: box.descent) { ctx, origin in
                box.draw(ctx, origin)
                ctx.fill(CGRect(x: origin.x, y: origin.y + box.ascent + gap, width: box.width, height: thickness))
            }
        case .delimited(let open, let inner, let close):
            let box = layout(inner, style)
            let height = max(box.ascent - style.axis, box.descent + style.axis) * 2
            return stack([stretched(open, height: height, style), box, stretched(close, height: height, style)])
        case .bigDelim(let symbol, let factor):
            return stretched(symbol, height: style.size * factor, style)
        case .grid(let rows, let alignment, let left, let right):
            let grid = gridBox(rows, alignment, style)
            let height = max(grid.ascent - style.axis, grid.descent + style.axis) * 2
            return stack([stretched(left, height: height, style), spacer(style.size * 0.15), grid,
                          spacer(style.size * 0.15), stretched(right, height: height, style)])
        }
    }

    private static func bigOperator(_ symbol: String, _ style: Style) -> Box {
        let factor: CGFloat = style.display ? 1.7 : 1.15
        let box = symbolBox(symbol, Style(size: style.size * factor, display: false, base: style.base))
        // 수학 축에 맞춰 세로 가운데에 놓는다
        let shift = style.axis - (box.ascent - box.descent) / 2
        return Box(width: box.width, ascent: box.ascent + shift, descent: box.descent - shift) { ctx, origin in
            box.draw(ctx, CGPoint(x: origin.x, y: origin.y + shift))
        }
    }

    private static func scripts(base: Atom, sup: [Atom]?, sub: [Atom]?, _ style: Style, forceLimits: Bool = false) -> Box {
        let baseBox = layout(base, style)
        let script = style.script
        let supBox = sup.map { layout($0, script) }
        let subBox = sub.map { layout($0, script) }
        // 합·극한 등은 가운데 위아래에 놓는다 (본문 수식에서는 옆에)
        var limits = forceLimits
        if style.display {
            if case .bigOp(_, let l) = base { limits = l }
            if case .function(_, let l) = base { limits = l }
        }
        if limits {
            let gap = style.size * 0.12
            let width = max(baseBox.width, supBox?.width ?? 0, subBox?.width ?? 0)
            let ascent = baseBox.ascent + (supBox.map { $0.ascent + $0.descent + gap } ?? 0)
            let descent = baseBox.descent + (subBox.map { $0.ascent + $0.descent + gap } ?? 0)
            let stacked = Box(width: width, ascent: ascent, descent: descent) { ctx, origin in
                baseBox.draw(ctx, CGPoint(x: origin.x + (width - baseBox.width) / 2, y: origin.y))
                if let supBox {
                    supBox.draw(ctx, CGPoint(x: origin.x + (width - supBox.width) / 2, y: origin.y + baseBox.ascent + gap + supBox.descent))
                }
                if let subBox {
                    subBox.draw(ctx, CGPoint(x: origin.x + (width - subBox.width) / 2, y: origin.y - baseBox.descent - gap - subBox.ascent))
                }
            }
            stacked.kind = baseBox.kind
            return stacked
        }
        let supShift = max(baseBox.ascent - style.size * 0.25, style.size * 0.38)
        var subShift = max(baseBox.descent + style.size * 0.05, style.size * 0.2)
        if let supBox, let subBox {
            // 위아래 첨자가 겹치지 않게
            let overlap = (supShift - supBox.descent) - (subBox.ascent - subShift)
            if overlap < style.size * 0.08 { subShift += style.size * 0.08 - overlap }
        }
        let gap = style.size * 0.05
        let scriptWidth = max(supBox?.width ?? 0, subBox?.width ?? 0)
        let ascent = max(baseBox.ascent, (supBox?.ascent ?? -supShift) + supShift)
        let descent = max(baseBox.descent, (subBox?.descent ?? -subShift) + subShift)
        let box = Box(width: baseBox.width + gap + scriptWidth, ascent: ascent, descent: descent) { ctx, origin in
            baseBox.draw(ctx, origin)
            let x = origin.x + baseBox.width + gap
            supBox?.draw(ctx, CGPoint(x: x, y: origin.y + supShift))
            subBox?.draw(ctx, CGPoint(x: x, y: origin.y - subShift))
        }
        box.kind = baseBox.kind
        return box
    }

    private static func fraction(_ numerator: [Atom], _ denominator: [Atom], line: Bool, _ style: Style) -> Box {
        let inner = style.display ? Style(size: style.size, display: false, base: style.base) : style.script
        let top = layout(numerator, inner), bottom = layout(denominator, inner)
        let width = max(top.width, bottom.width) + style.size * 0.25
        let thickness = max(style.size * 0.055, 0.6), gap = style.size * 0.14
        let topShift = style.axis + gap + thickness / 2 + top.descent
        let bottomShift = gap + thickness / 2 - style.axis + bottom.ascent
        return Box(width: width + style.size * 0.1, ascent: topShift + top.ascent, descent: bottomShift + bottom.descent) { ctx, origin in
            let x = origin.x + style.size * 0.05
            top.draw(ctx, CGPoint(x: x + (width - top.width) / 2, y: origin.y + topShift))
            bottom.draw(ctx, CGPoint(x: x + (width - bottom.width) / 2, y: origin.y - bottomShift))
            if line { ctx.fill(CGRect(x: x, y: origin.y + style.axis - thickness / 2, width: width, height: thickness)) }
        }
    }

    private static func radical(_ inner: [Atom], index: [Atom]?, _ style: Style) -> Box {
        let box = layout(inner, style)
        let indexBox = index.map { layout($0, style.script.script) }
        let thickness = max(style.size * 0.055, 0.6), gap = style.size * 0.14
        let hookWidth = style.size * 0.55
        let height = box.ascent + box.descent + gap
        let lead = max((indexBox?.width ?? 0) - hookWidth * 0.45, 0)
        let width = lead + hookWidth + box.width + style.size * 0.08
        return Box(width: width, ascent: box.ascent + gap + thickness, descent: box.descent) { ctx, origin in
            let left = origin.x + lead
            let top = origin.y + box.ascent + gap + thickness / 2
            let bottom = origin.y - box.descent
            ctx.setLineWidth(thickness)
            ctx.setLineJoin(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: left, y: bottom + height * 0.42))
            ctx.addLine(to: CGPoint(x: left + hookWidth * 0.22, y: bottom + height * 0.5))
            ctx.addLine(to: CGPoint(x: left + hookWidth * 0.5, y: bottom))
            ctx.addLine(to: CGPoint(x: left + hookWidth, y: top))
            ctx.addLine(to: CGPoint(x: left + hookWidth + box.width + style.size * 0.08, y: top))
            ctx.strokePath()
            box.draw(ctx, CGPoint(x: left + hookWidth, y: origin.y))
            indexBox?.draw(ctx, CGPoint(x: origin.x, y: bottom + height * 0.62))
        }
    }

    private static func accent(_ mark: String, _ inner: [Atom], _ style: Style) -> Box {
        let box = layout(inner, style)
        let markBox = glyphs(mark, font: mathFont(mark == "→" ? style.size * 0.7 : style.size))
        let gap = style.size * 0.04
        let shift = box.ascent + gap - (mark == "→" ? markBox.descent : markBox.ascent - style.size * 0.12)
        let width = max(box.width, markBox.width)
        return Box(width: width, ascent: max(box.ascent, shift + markBox.ascent), descent: box.descent) { ctx, origin in
            box.draw(ctx, CGPoint(x: origin.x + (width - box.width) / 2, y: origin.y))
            markBox.draw(ctx, CGPoint(x: origin.x + (width - markBox.width) / 2, y: origin.y + shift))
        }
    }

    /// 괄호를 내용 높이에 맞게 키운다 (글자 크기를 늘려 축 가운데에 놓는다)
    private static func stretched(_ symbol: String, height: CGFloat, _ style: Style) -> Box {
        guard !symbol.isEmpty else { return spacer(0) }
        let natural = symbolBox(symbol, style)
        let naturalHeight = max(natural.ascent + natural.descent, 1)
        let box = height <= naturalHeight * 1.1 ? natural : symbolBox(symbol, Style(size: style.size * height / naturalHeight, display: false, base: style.base))
        let shift = style.axis - (box.ascent - box.descent) / 2
        return Box(width: box.width, ascent: box.ascent + shift, descent: box.descent - shift) { ctx, origin in
            box.draw(ctx, CGPoint(x: origin.x, y: origin.y + shift))
        }
    }

    private static func gridBox(_ rows: [[[Atom]]], _ alignment: GridAlignment, _ style: Style) -> Box {
        let inner = Style(size: style.size, display: false, base: style.base)
        let cells = rows.map { $0.map { layout($0, inner) } }
        let columns = cells.map(\.count).max() ?? 0
        let widths = (0..<columns).map { c in cells.compactMap { c < $0.count ? $0[c].width : nil }.max() ?? 0 }
        let columnGap = alignment == .rightLeft ? 0 : style.size * 0.7
        let rowGap = style.size * 0.28
        let heights = cells.map { row in (row.map(\.ascent).max() ?? style.size * 0.7, row.map(\.descent).max() ?? style.size * 0.2) }
        let total = heights.reduce(0) { $0 + $1.0 + $1.1 } + rowGap * CGFloat(max(cells.count - 1, 0))
        let ascent = total / 2 + style.axis, descent = total / 2 - style.axis
        let width = widths.reduce(0, +) + columnGap * CGFloat(max(columns - 1, 0))
        return Box(width: width, ascent: ascent, descent: descent) { ctx, origin in
            var y = origin.y + ascent
            for (r, row) in cells.enumerated() {
                y -= heights[r].0
                var x = origin.x
                for c in 0..<columns {
                    if c < row.count {
                        let cell = row[c]
                        let offset: CGFloat
                        switch alignment {
                        case .center: offset = (widths[c] - cell.width) / 2
                        case .left: offset = 0
                        case .rightLeft: offset = c % 2 == 0 ? widths[c] - cell.width : 0
                        }
                        cell.draw(ctx, CGPoint(x: x + offset, y: y))
                    }
                    x += widths[c] + columnGap
                }
                y -= heights[r].1 + rowGap
            }
        }
    }
}
