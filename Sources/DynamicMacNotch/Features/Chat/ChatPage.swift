import AppKit
import SwiftUI

/// 홈의 AI 채팅 페이지.
/// 처음에는 입력 칸만 있는 작은 노치 → 보내면 입력 칸 대신 '생각 중…' → 답변이 다 오면 커져서 대화와 입력 칸을 보여 준다.
/// 다시 질문하면 작은 노치의 '생각 중…'으로 돌아가며 이를 반복한다.
struct ChatPage: View {
    @ObservedObject var store: ChatStore
    /// 노치가 다 열려 이 페이지가 떠 있는 상태
    var active: Bool
    var collapse: () -> Void
    var openSettings: () -> Void
    /// 입력 칸이 여러 줄로 늘어난 만큼 작은 노치를 키운다
    var setInputExtra: (CGFloat) -> Void

    @ObservedObject private var settings = AppSettings.shared

    /// 평소에는 가벼운 글자로 보여 주고, 누를 때만 실제 입력 칸(AppKit)을 띄운다 (메모와 같음)
    private enum Field { case title, input }
    private let editingState = State(initialValue: Field?.none)
    private let inputHeightState = State(initialValue: ChatInputView.lineHeight)

    private var editing: Field? {
        get { editingState.wrappedValue }
        nonmutating set { editingState.wrappedValue = newValue }
    }

    private var live: Bool { active && editing != nil && !store.isStreaming }

    var body: some View {
        VStack(spacing: 6) {
            header
            if store.isLarge { content }
            bottom
        }
        .padding(.top, 2)
        .onAppear { store.pageAppeared() }
        .onChange(of: active) { _, isActive in
            if !isActive { stopEditing() }
        }
        .onDisappear {
            stopEditing()
            store.pageDisappeared()
        }
    }

    // MARK: - 머리글

    private var header: some View {
        HStack(spacing: 6) {
            Group {
                if live {
                    MemoTitleField(text: store.title, memoID: store.currentID, focus: editing == .title) { store.setTitle($0) }
                        .padding(.leading, 2)
                } else {
                    Text(store.title.isEmpty ? T("새 채팅", "New Chat") : store.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(store.title.isEmpty ? 0.35 : 1))
                        .lineLimit(1)
                        .padding(.leading, 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { if !store.isStreaming { startEditing(.title) } }
                }
            }
            .frame(height: 20)
            .help("\(settings.chatService.name) · \(settings.chatModel(for: settings.chatService))")
            // 답변을 기다리는 동안에는 이 채팅에 머문다 (중지만 가능)
            if !store.isStreaming {
                iconButton("square.and.pencil", help: T("새 채팅", "New Chat")) {
                    store.newChat()
                    startEditing(.input)
                }
                iconButton(store.showList ? "sidebar.trailing" : "list.bullet", help: T("채팅 목록", "Chat List"), active: store.showList) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { store.toggleList() }
                }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ChatIcon.image(symbol, size: 11, weight: .semibold)
                .foregroundStyle(.white.opacity(active ? 1 : 0.7))
                .frame(width: 22, height: 20)
                .background(Color.white.opacity(active ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 대화

    private var content: some View {
        GeometryReader { geo in
            HStack(spacing: 8) {
                conversation
                if store.showList {
                    ChatListView(store: store)
                        .frame(width: (geo.size.width - 8) / 3)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.entries) { entry in
                        bubble(entry).id(entry.id)
                    }
                    status
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 10)   // 겹쳐 뜨는 스크롤 막대가 글자를 가리지 않게
            }
            .scrollIndicators(.automatic)
            .onAppear {
                // 마지막 질문이 맨 위에 오도록 내린다 (긴 답변을 처음부터 읽게). 레이아웃이 끝난 뒤에 한다.
                guard let id = store.entries.last(where: { $0.role == .user })?.id else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
            }
        }
        .id(store.currentID)   // 다른 채팅을 불러오면 그 채팅의 마지막 질문부터
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
            VStack(alignment: .leading, spacing: 2) {
                ChatAnswerView(text: entry.rendered ?? NSAttributedString(string: entry.text))
                ChatCopyButton(text: entry.text)
            }
        }
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

    // MARK: - 아래 줄 (입력 칸 또는 생각 중)

    private var bottom: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Group {
                if store.isStreaming {
                    HStack(spacing: 7) {
                        SpinnerRing(tint: .white.opacity(0.75))
                            .frame(width: 13, height: 13)
                        Text(T("생각 중…", "Thinking…"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else if live {
                    ChatInputView(text: store.draft, revision: store.draftRevision, focus: editing == .input,
                                  onChange: { store.draft = $0 },
                                  onHeightChange: inputHeightChanged,
                                  onSend: store.send,
                                  onEscape: collapse)
                } else {
                    Text(store.draft.isEmpty ? T("무엇이든 물어보세요", "Ask anything") : store.draft)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(store.draft.isEmpty ? 0.35 : 0.92))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { startEditing(.input) }
                }
            }
            .frame(height: store.isStreaming ? ChatInputView.lineHeight : inputHeightState.wrappedValue)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.white.opacity(store.isStreaming ? 0 : 0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Button(action: store.isStreaming ? store.stop : store.send) {
                ChatIcon.image(store.isStreaming ? "stop.fill" : "arrow.up", size: 11, weight: .bold)
                    .foregroundStyle(.black)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.9), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(store.isStreaming ? T("중지", "Stop") : T("보내기", "Send"))
        }
        .onChange(of: store.isStreaming) { _, streaming in
            // 생각 중에는 입력 칸이 없으므로 한 줄 높이로 돌아간다
            if streaming { inputHeightChanged(ChatInputView.lineHeight) }
        }
    }

    private func inputHeightChanged(_ height: CGFloat) {
        inputHeightState.wrappedValue = height
        setInputExtra(height - ChatInputView.lineHeight)
    }

    private func startEditing(_ field: Field) {
        guard active else { return }
        editing = field
    }

    private func stopEditing() {
        guard editing != nil else { return }
        editing = nil
        inputHeightChanged(ChatInputView.lineHeight)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

/// 채팅 목록 (오른쪽 1/3). 누르면 불러오고, 우클릭으로 삭제.
private struct ChatListView: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 3) {
                ForEach(store.summaries) { chat in
                    Button { store.open(chat.id) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chat.title.isEmpty ? T("제목 없음", "Untitled") : chat.title)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(chat.title.isEmpty ? 0.5 : 0.95))
                            Text(chat.updated.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(chat.id == store.currentID ? 0.16 : 0.05),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(T("삭제", "Delete"), role: .destructive) { store.delete(chat.id) }
                    }
                }
                if store.summaries.isEmpty {
                    Text(T("저장된 채팅이 없습니다", "No saved chats"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 8)
                }
            }
        }
    }
}

/// 입력 칸. Enter 보내기, ⇧Enter 줄바꿈, Esc 닫기. 세 줄까지 늘어난다.
struct ChatInputView: NSViewRepresentable {
    static let lineHeight: CGFloat = 16
    private static let maxLines: CGFloat = 3

    var text: String
    var revision: Int
    /// 나타나자마자 커서를 둔다
    var focus: Bool
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
        if focus {
            let coordinator = context.coordinator
            tv.onWindow = { [weak tv] in
                guard let tv else { return }
                tv.window?.makeKey()
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                coordinator.reportHeight(tv)
            }
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
        // 제목을 쓰다가 새 채팅을 눌러도 커서가 입력 칸으로 오게 한다
        if focus { DispatchQueue.main.async { [weak tv] in tv?.window?.makeFirstResponder(tv) } }
    }
}
