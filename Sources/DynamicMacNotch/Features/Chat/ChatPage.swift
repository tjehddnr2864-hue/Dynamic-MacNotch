import AppKit
import SwiftUI

/// 홈의 AI 채팅 페이지: 위 대화, 아래 입력 칸.
struct ChatPage: View {
    @ObservedObject var store: ChatStore
    /// 노치가 다 열려 이 페이지가 떠 있는 상태
    var active: Bool
    var collapse: () -> Void
    var openSettings: () -> Void

    @ObservedObject private var settings = AppSettings.shared

    /// 평소에는 가벼운 글자로 보여 주고, 누를 때만 실제 입력 칸(AppKit)을 띄운다 (메모와 같음)
    private let editingState = State(initialValue: false)
    private let inputHeightState = State(initialValue: ChatInputView.lineHeight)
    /// 맨 아래를 보고 있는지 (위로 올려 읽는 중이면 자동으로 내리지 않는다)
    private let followState = State(initialValue: true)

    private var editing: Bool {
        get { editingState.wrappedValue }
        nonmutating set { editingState.wrappedValue = newValue }
    }
    private var follow: Bool {
        get { followState.wrappedValue }
        nonmutating set { followState.wrappedValue = newValue }
    }

    private static let scrollSpace = "chatScroll"
    private static let bottomID = "chatBottom"
    /// 맨 아래에서 이만큼 이내면 '맨 아래를 보는 중'으로 본다 (글이 늘어나는 만큼의 여유)
    private static let followMargin: CGFloat = 60

    var body: some View {
        VStack(spacing: 6) {
            header
            conversation
            input
        }
        .padding(.top, 2)
        .onAppear { store.setVisible(true) }
        .onChange(of: active) { _, isActive in
            if !isActive { stopEditing() }
        }
        .onDisappear {
            stopEditing()
            store.setVisible(false)
        }
    }

    // MARK: - 머리글

    private var header: some View {
        let service = settings.chatService
        return HStack(spacing: 6) {
            Text("\(service.name) · \(settings.chatModel(for: service))")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            iconButton("doc.on.doc", help: T("답변 복사", "Copy Answer")) { store.copyLastAnswer() }
                .disabled(store.lastAnswer == nil)
                .opacity(store.lastAnswer == nil ? 0.35 : 1)
            iconButton("square.and.pencil", help: T("새 대화", "New Chat")) {
                store.newChat()
                follow = true
                startEditing()
            }
        }
        .frame(height: 18)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 대화

    private var conversation: some View {
        GeometryReader { box in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        if store.entries.isEmpty && store.partial.isEmpty && !store.isStreaming && store.error == nil {
                            Text(T("무엇이든 물어보세요", "Ask anything"))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.35))
                                .frame(maxWidth: .infinity, minHeight: box.size.height)
                        }
                        ForEach(store.entries) { entry in
                            bubble(entry)
                        }
                        if !store.partial.isEmpty {
                            answerText(Text(store.partial))
                        } else if store.isStreaming {
                            Text(T("생각 중…", "Thinking…"))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        status
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                            .background(GeometryReader { marker in
                                Color.clear.preference(key: ChatBottomKey.self,
                                                       value: marker.frame(in: .named(Self.scrollSpace)).maxY)
                            })
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 10)   // 겹쳐 뜨는 스크롤 막대가 글자를 가리지 않게
                }
                .coordinateSpace(name: Self.scrollSpace)
                .scrollIndicators(.automatic)
                .onPreferenceChange(ChatBottomKey.self) { bottom in
                    let atBottom = bottom <= box.size.height + Self.followMargin
                    if atBottom != follow { follow = atBottom }
                }
                .onAppear {
                    // 다시 열면 마지막 답변부터 보이게 (레이아웃이 끝난 뒤 내린다)
                    DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
                .onChange(of: store.partial) { _, _ in
                    if follow { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
                .onChange(of: store.entries) { _, _ in
                    // 새 질문을 보내면 언제나 맨 아래로
                    if store.entries.last?.role == .user { follow = true }
                    if follow { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ entry: ChatStore.Entry) -> some View {
        if entry.role == .user {
            HStack {
                Spacer(minLength: 32)
                Text(entry.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        } else {
            answerText(Text(entry.rendered ?? AttributedString(entry.text)))
        }
    }

    private func answerText(_ text: Text) -> some View {
        text
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.92))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var status: some View {
        if let error = store.error {
            VStack(alignment: .leading, spacing: 4) {
                Text(error.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                if error == .missingKey || error == .noModel || error == .unauthorized || error == .modelNotFound {
                    Button(T("설정 열기", "Open Settings"), action: openSettings)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        } else if store.truncated {
            Text(T("답변이 길어 중간에 끊겼습니다", "The answer was cut off for length"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: - 입력

    private var input: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Group {
                if active && editing {
                    ChatInputView(text: store.draft, revision: store.draftRevision,
                                  onChange: { store.draft = $0 },
                                  onHeightChange: { inputHeightState.wrappedValue = $0 },
                                  onSend: send,
                                  onEscape: escape)
                } else {
                    Text(store.draft.isEmpty ? T("질문 입력", "Ask a question") : store.draft)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(store.draft.isEmpty ? 0.35 : 0.92))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { startEditing() }
                }
            }
            .frame(height: inputHeightState.wrappedValue)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Button(action: store.isStreaming ? store.stop : send) {
                Image(systemName: store.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.9), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(store.isStreaming ? T("중지", "Stop") : T("보내기", "Send"))
        }
    }

    private func send() {
        follow = true
        store.send()
    }

    private func escape() {
        if store.isStreaming {
            store.stop()
        } else {
            collapse()
        }
    }

    private func startEditing() {
        guard active else { return }
        editing = true
    }

    private func stopEditing() {
        guard editing else { return }
        editing = false
        inputHeightState.wrappedValue = ChatInputView.lineHeight
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

private struct ChatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 입력 칸. Enter 보내기, ⇧Enter 줄바꿈, Esc 중지·닫기. 세 줄까지 늘어난다.
struct ChatInputView: NSViewRepresentable {
    static let lineHeight: CGFloat = 16
    private static let maxLines: CGFloat = 3

    var text: String
    var revision: Int
    var onChange: (String) -> Void
    var onHeightChange: (CGFloat) -> Void
    var onSend: () -> Void
    var onEscape: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputView
        var revision: Int
        init(_ parent: ChatInputView) {
            self.parent = parent
            revision = parent.revision
        }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.onChange(tv.string)
            reportHeight(tv)
        }

        func reportHeight(_ tv: NSTextView) {
            guard let manager = tv.layoutManager, let container = tv.textContainer else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).height
            let height = min(max(used.rounded(.up), ChatInputView.lineHeight), ChatInputView.lineHeight * ChatInputView.maxLines)
            parent.onHeightChange(height)
        }

        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            // 한글 조합 중의 Enter·Esc는 입력기가 처리한다
            guard !tv.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    tv.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSend()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero

        // 가벼운 TextKit 1 + 맞춤법·예측 끔 (메모와 같은 이유)
        let tv = MemoNSTextView(usingTextLayoutManager: false)
        MemoNSTextView.disableExtras(tv)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textColor = .white
        tv.insertionPointColor = .white
        tv.font = .systemFont(ofSize: 12)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.typingAttributes = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12)]
        tv.string = text
        tv.delegate = context.coordinator
        scroll.documentView = tv
        let coordinator = context.coordinator
        tv.onWindow = { [weak tv] in
            guard let tv else { return }
            tv.window?.makeKey()
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            coordinator.reportHeight(tv)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // 보낸 뒤 비우기 등 바깥에서 바뀐 경우만 반영한다 (다시 그려질 때 입력 중인 글을 덮어쓰지 않게)
        guard context.coordinator.revision != revision, let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.revision = revision
        tv.string = text
        context.coordinator.reportHeight(tv)
    }
}
