import AppKit
import SwiftUI

/// 답변 본문. 드래그로 선택해 ⌘C로 복사하고, 링크를 누르면 기본 브라우저로 연다.
struct ChatAnswerView: NSViewRepresentable {
    let text: NSAttributedString

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            // 웹 주소만 연다 (모델이 쓴 다른 형식의 링크로 앱이나 파일을 열지 않게)
            guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return true }
            NSWorkspace.shared.open(url)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ChatAnswerTextView {
        let tv = ChatAnswerTextView(usingTextLayoutManager: false)
        MemoNSTextView.disableExtras(tv)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.importsGraphics = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.28)]
        tv.linkTextAttributes = [.foregroundColor: NSColor(red: 0.45, green: 0.72, blue: 1, alpha: 1),
                                 .underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .cursor: NSCursor.pointingHand]
        tv.delegate = context.coordinator
        tv.textStorage?.setAttributedString(text)
        return tv
    }

    func updateNSView(_ tv: ChatAnswerTextView, context: Context) {
        if tv.textStorage?.isEqual(to: text) != true { tv.textStorage?.setAttributedString(text) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: ChatAnswerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite,
              let manager = tv.layoutManager, let container = tv.textContainer else { return nil }
        tv.fitFormulas(to: width)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(manager.usedRect(for: container).height))
    }
}

final class ChatAnswerTextView: MemoNSTextView {
    #if DEV
    /// 개발용: 시험 중 사용자의 클립보드를 덮어쓰지 않게 별도 이름의 클립보드에 쓴다
    static var testPasteboard: NSPasteboard? = ProcessInfo.processInfo.environment["DMN_TEST_PASTEBOARD"].map { NSPasteboard(name: .init($0)) }
    #endif

    /// 복사는 여기서만 클립보드에 쓴다
    static func write(_ text: String) {
        var board = NSPasteboard.general
        #if DEV
        if let test = testPasteboard { board = test }
        #endif
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// 수식은 그림이 아니라 LaTeX 원문으로 복사한다
    override func copy(_ sender: Any?) {
        guard let storage = textStorage, selectedRange().length > 0 else { return }
        Self.write(ChatMarkdown.plainText(storage, range: selectedRange()))
    }

    /// 답변을 선택한 상태에서 ⌘V를 눌러도 입력 칸에 붙여 넣는다
    override func paste(_ sender: Any?) {
        guard let input = window?.contentView.flatMap(Self.findInput) else { return }
        window?.makeFirstResponder(input)
        input.paste(sender)
    }

    private static func findInput(in view: NSView) -> NSTextView? {
        if let tv = view as? MemoNSTextView, tv.isEditable { return tv }
        for sub in view.subviews {
            if let found = findInput(in: sub) { return found }
        }
        return nil
    }

    /// 칸이 좁아지면(채팅 목록을 열 때) 넘치는 수식을 그 폭에 맞게 줄이고, 넓어지면 되돌린다
    func fitFormulas(to width: CGFloat) {
        guard let storage = textStorage else { return }
        var changed = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let math = value as? MathAttachment else { return }
            let natural = math.naturalBounds
            let scale = min(1, width / natural.width)
            let fitted = CGRect(x: 0, y: natural.minY * scale, width: natural.width * scale, height: natural.height * scale)
            if fitted != math.bounds {
                math.bounds = fitted
                changed = true
            }
        }
        if changed, let manager = layoutManager {
            manager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        }
    }
}

/// 답변 아래의 복사 버튼 (누르면 잠깐 체크 표시)
struct ChatCopyButton: View {
    let text: String
    private let copiedState = State(initialValue: false)

    var body: some View {
        Button {
            ChatAnswerTextView.write(text)
            copiedState.wrappedValue = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedState.wrappedValue = false }
        } label: {
            Image(systemName: copiedState.wrappedValue ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(copiedState.wrappedValue ? 0.9 : 0.5))
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(T("답변 복사", "Copy Answer"))
    }
}
