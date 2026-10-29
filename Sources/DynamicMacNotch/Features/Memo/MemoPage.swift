import AppKit
import SwiftUI

/// 홈의 메모 페이지: 위에 고정된 제목, 아래 스크롤되는 본문.
/// 오른쪽 위 목록 아이콘을 누르면 본문이 왼쪽으로 밀리며 오른쪽 1/3에 메모 목록이 나온다.
struct MemoPage: View {
    @ObservedObject var store: MemoStore
    /// 노치가 다 열려 이 페이지가 떠 있는 상태 (열리고 닫히는 애니메이션 중에는 false)
    var active: Bool

    /// 지금 쓰는 칸. 평소에는 가벼운 SwiftUI 글자로 보여 주고, 제목·본문을 누를 때만 실제 입력 칸(AppKit)을 띄운다.
    /// (입력 칸은 화면에 붙었다 떨어질 때마다 메모리를 조금씩 남기므로, 보기만 할 때는 만들지 않는다)
    enum Field { case title, body }
    private let editingState = State(initialValue: Field?.none)
    /// 본문을 누른 위치 (그 자리에 커서를 놓는다)
    private let clickState = State(initialValue: CGPoint?.none)
    private var editing: Field? {
        get { editingState.wrappedValue }
        nonmutating set { editingState.wrappedValue = newValue }
    }
    private var clickPoint: CGPoint? {
        get { clickState.wrappedValue }
        nonmutating set { clickState.wrappedValue = newValue }
    }

    var body: some View {
        let live = active && editing != nil
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Group {
                    if live {
                        MemoTitleField(text: store.current?.title ?? "", memoID: store.current?.id,
                                       focus: editing == .title) { store.setTitle($0) }
                            .padding(.leading, 2)   // 보기 화면의 제목과 같은 위치
                    } else {
                        let title = store.current?.title ?? ""
                        Text(title.isEmpty ? T("제목", "Title") : title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(title.isEmpty ? 0.35 : 1))
                            .lineLimit(1)
                            .padding(.leading, 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { startEditing(.title) }
                    }
                }
                .frame(height: 20)
                iconButton("square.and.pencil", help: T("새 메모", "New Memo")) {
                    store.createNew()
                    startEditing(.title)
                }
                iconButton(store.showList ? "sidebar.trailing" : "list.bullet", help: T("메모 목록", "Memo List"),
                           active: store.showList) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { store.toggleList() }
                }
            }
            GeometryReader { geo in
                HStack(spacing: 8) {
                    Group {
                        if live {
                            MemoTextView(text: store.current?.body ?? "", memoID: store.current?.id,
                                         focus: editing == .body, clickPoint: clickPoint) { store.setBody($0) }
                        } else {
                            // 보기: 넘치면 스크롤. 누른 자리부터 바로 이어서 쓸 수 있다.
                            // 글이 짧거나 비어 있어도 칸 전체를 누를 수 있게 최소 높이를 칸 높이로 (아래 빈 곳 = 맨 끝)
                            GeometryReader { box in
                                ScrollView(.vertical) {
                                    Text(store.current?.body ?? "")
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity, minHeight: box.size.height, alignment: .topLeading)
                                        .contentShape(Rectangle())
                                        .onTapGesture(coordinateSpace: .local) { p in startEditing(.body, at: p) }
                                }
                                .scrollIndicators(.automatic)
                            }
                        }
                    }
                        // 본문은 노치와 같은 검은 바탕 (상자 없음). 비어 있으면 쓸 자리를 연한 '내용'으로 알려 준다.
                        .padding(.leading, 2)
                        .background(alignment: .topLeading) {
                            if (store.current?.body ?? "").isEmpty {
                                Text(T("내용", "Note"))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.white.opacity(0.3))
                                    .padding(.leading, 2)
                                    .allowsHitTesting(false)
                            }
                        }
                    if store.showList {
                        MemoListView(store: store)
                            .frame(width: (geo.size.width - 8) / 3)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .padding(.top, 2)
        .onAppear { store.pageAppeared() }
        .onChange(of: active) { _, isActive in
            // 노치가 접히기 시작하면 바로 보기 화면으로 (입력 칸 없이 애니메이션)
            if !isActive { stopEditing() }
        }
        .onChange(of: store.current?.id) { _, _ in
            // 목록에서 다른 메모를 불러오면 보기 화면으로
            if editing == .body { clickPoint = nil }
        }
        .onDisappear {
            stopEditing()
            store.pageDisappeared()
        }
    }

    private func startEditing(_ field: Field, at point: CGPoint? = nil) {
        guard active else { return }
        clickPoint = point
        editing = field
    }

    private func stopEditing() {
        guard editing != nil else { return }
        editing = nil
        clickPoint = nil
        // 입력 칸이 사라지면 키보드 포커스를 놓는다
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func iconButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(active ? 1 : 0.7))
                .frame(width: 22, height: 20)
                .background(Color.white.opacity(active ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 메모 목록 (오른쪽 1/3). 누르면 불러오고, 우클릭으로 삭제.
private struct MemoListView: View {
    @ObservedObject var store: MemoStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 3) {
                ForEach(store.summaries ?? []) { m in
                    let selected = m.id == store.current?.id
                    Button { store.open(m.id) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.title.isEmpty ? T("제목 없음", "Untitled") : m.title)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(m.title.isEmpty ? 0.5 : 0.95))
                            Text(m.preview.isEmpty ? Self.date(m.updated) : m.preview)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(selected ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(T("삭제", "Delete"), role: .destructive) { store.delete(m.id) }
                    }
                }
                if store.summaries?.isEmpty ?? true {
                    Text(T("저장된 메모가 없습니다", "No saved memos"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 8)
                }
            }
        }
    }

    private static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}

/// 제목 칸 (한 줄). Enter를 누르면 본문으로 넘어간다.
private struct MemoTitleField: NSViewRepresentable {
    var text: String
    var memoID: UUID?
    /// 나타나자마자 커서를 둔다 (제목을 눌러 쓰기 시작)
    var focus: Bool
    var onChange: (String) -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MemoTitleField
        var shownID: UUID?
        init(_ parent: MemoTitleField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            parent.onChange(f.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertTab(_:)) else { return false }
            // 본문으로
            if let window = control.window, let body = Self.findTextView(in: window.contentView) {
                window.makeFirstResponder(body)
            }
            return true
        }

        private static func findTextView(in view: NSView?) -> NSTextView? {
            guard let view else { return nil }
            if let t = view as? MemoNSTextView { return t }
            for sub in view.subviews { if let t = findTextView(in: sub) { return t } }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = KeyTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.textColor = .white
        f.font = .systemFont(ofSize: 14, weight: .semibold)
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.placeholderAttributedString = NSAttributedString(
            string: T("제목", "Title"),
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.35), .font: NSFont.systemFont(ofSize: 14, weight: .semibold)])
        f.delegate = context.coordinator
        f.stringValue = text
        context.coordinator.shownID = memoID
        if focus {
            f.onWindow = { [weak f] in
                guard let f else { return }
                f.window?.makeKey()
                f.window?.makeFirstResponder(f)
                f.currentEditor()?.selectedRange = NSRange(location: (f.stringValue as NSString).length, length: 0)
            }
        }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        // 다른 메모를 불러왔을 때만 내용을 바꾼다 (입력 중 커서가 튀지 않게)
        if context.coordinator.shownID != memoID {
            context.coordinator.shownID = memoID
            f.stringValue = text
        }
    }
}

/// 본문 칸 (여러 줄, 넘치면 스크롤)
private struct MemoTextView: NSViewRepresentable {
    var text: String
    var memoID: UUID?
    /// 나타나자마자 커서를 둔다 (본문을 눌러 쓰기 시작)
    var focus: Bool
    /// 보기 화면에서 누른 위치 (그 자리에 커서). nil이면 맨 끝.
    var clickPoint: CGPoint?
    var onChange: (String) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MemoTextView
        var shownID: UUID?
        init(_ parent: MemoTextView) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let t = note.object as? NSTextView else { return }
            parent.onChange(t.string)
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

        // 가벼운 TextKit 1 + 맞춤법·자동 고침·예측·쓰기 도구 끔 (켜 두면 처음 열 때 수십 MB를 불러온다)
        let tv = MemoNSTextView(usingTextLayoutManager: false)
        MemoNSTextView.disableExtras(tv)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textColor = .white
        tv.insertionPointColor = .white
        tv.font = .systemFont(ofSize: 12.5)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0   // 보기 화면의 SwiftUI 글자와 같은 위치
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.typingAttributes = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12.5)]
        tv.string = text
        tv.delegate = context.coordinator
        scroll.documentView = tv
        context.coordinator.shownID = memoID
        if focus {
            let point = clickPoint
            // 창에 붙고 크기가 정해진 뒤 누른 자리(없으면 맨 끝)에 커서를 두고 보이게 한다
            tv.onWindow = { [weak tv] in
                guard let tv else { return }
                tv.window?.makeKey()
                tv.window?.makeFirstResponder(tv)
                let length = (tv.string as NSString).length
                let index = point.map { min(tv.characterIndexForInsertion(at: $0), length) } ?? length
                tv.setSelectedRange(NSRange(location: index, length: 0))
                tv.scrollRangeToVisible(NSRange(location: index, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView, context.coordinator.shownID != memoID else { return }
        // 다른 메모를 불러왔을 때만 내용을 바꾼다 (맨 위로)
        context.coordinator.shownID = memoID
        tv.string = text
        tv.scrollToBeginningOfDocument(nil)
        tv.undoManager?.removeAllActions()
    }
}

/// 누르면 노치 창이 키보드를 받도록 한다 (평소에는 다른 앱의 포커스를 가져오지 않음)
final class MemoNSTextView: NSTextView {
    /// 창에 붙은 직후 한 번 (커서 놓기)
    var onWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let action = onWindow else { return }
        // SwiftUI가 붙였다 떼었다 다시 붙일 수 있어, 실제로 창에 붙어 있을 때 한 번만 실행한다
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.onWindow != nil else { return }
            self.onWindow = nil
            action()
        }
    }

    static func disableExtras(_ tv: NSTextView) {
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.inlinePredictionType = .no
        if #available(macOS 15.0, *) { tv.writingToolsBehavior = .none }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }
}

private final class KeyTextField: NSTextField {
    var onWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let action = onWindow else { return }
        // SwiftUI가 붙였다 떼었다 다시 붙일 수 있어, 실제로 창에 붙어 있을 때 한 번만 실행한다
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.onWindow != nil else { return }
            self.onWindow = nil
            action()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }
}
