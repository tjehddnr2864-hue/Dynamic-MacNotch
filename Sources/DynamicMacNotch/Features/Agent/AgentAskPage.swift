import AppKit
import SwiftUI

/// 코딩 에이전트의 질문을 길게 눌러 연 팝업: 선택지와 맨 아래 '직접 입력'.
/// 질문이 여러 개면 하나씩 답하고, 마지막 답을 고르면 한꺼번에 보낸다.
struct AgentAskPage: View {
    @ObservedObject var store: AgentAskStore

    var body: some View {
        if let r = store.current {
            AgentAskContent(store: store, request: r).id(r.id)   // 질문이 바뀌면 고르던 상태를 새로
        }
    }

    // MARK: 크기 (팝업 높이를 질문에 맞춘다)

    static let rowHeight: CGFloat = 30, detailRowHeight: CGFloat = 38, rowSpacing: CGFloat = 4
    static let maxContent: CGFloat = 330

    /// 노치 아래 내용 높이
    static func contentHeight(_ r: AgentAsk.Request?) -> CGFloat {
        guard let r else { return 120 }
        // 위 여백 2 + 머리 줄 16 + 간격 8 … 간격 8 + 아래 줄 28 + 여유 8
        let header: CGFloat = 2 + 16 + 8, input: CGFloat = 8 + 28 + 8
        var body: CGFloat
        switch r.kind {
        case .permission:
            body = 18 + 8 + (r.detail.isEmpty ? 0 : lines(r.detail, perLine: 44, max: 3) * 14 + 8) + rowHeight
        case .question, .notice:
            body = r.questions.map { q in
                lines(q.question, perLine: 34, max: 3) * 18 + 8
                    + q.options.reduce(0) { $0 + ($1.detail.isEmpty ? rowHeight : detailRowHeight) } + CGFloat(max(0, q.options.count - 1)) * rowSpacing
            }.max() ?? 40
        }
        return min(maxContent, header + body + input)
    }

    private static func lines(_ text: String, perLine: Int, max: Int) -> CGFloat {
        CGFloat(Swift.min(max, Swift.max(1, Int((Double(text.count) / Double(perLine)).rounded(.up)))))
    }
}

private struct AgentAskContent: View {
    @ObservedObject var store: AgentAskStore
    let request: AgentAsk.Request
    private let indexState = State(initialValue: 0)
    private let answersState = State(initialValue: [String: String]())
    private let pickedState = State(initialValue: Set<String>())
    private let typedState = State(initialValue: "")
    /// 방금 고른 것 (선택지 이름, 또는 #send·#allow·#deny). 체크를 보인 뒤 잠깐 있다가 보낸다
    private let confirmedState = State(initialValue: String?.none)
    private var confirmed: String? { confirmedState.wrappedValue }
    /// 체크를 보여 주는 시간
    private static let confirmDelay: TimeInterval = 0.5

    /// 고른 것에 체크를 보이고, 0.5초 뒤에 보낸다 (그동안 다른 것은 누를 수 없음)
    private func confirm(_ key: String, then action: @escaping () -> Void) {
        guard confirmed == nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { confirmedState.wrappedValue = key }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmDelay) {
            action()
            confirmedState.wrappedValue = nil
        }
    }

    private func checkMark() -> some View {
        Image(systemName: "checkmark.circle.fill").font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white, request.agent.tint)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
    }

    private var index: Int { min(indexState.wrappedValue, max(0, request.questions.count - 1)) }
    private var typed: String { typedState.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // 넘칠 때만 스크롤 (선택지가 많거나 질문이 길 때)
            ViewThatFits(in: .vertical) {
                main
                ScrollView(.vertical, showsIndicators: false) { main }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 8) {
            if request.kind == .permission { permission } else if let q = request.questions[safe: index] { question(q) }
        }
    }

    // MARK: 머리 줄

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: request.agent.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(request.agent.tint)
            Text(request.project.isEmpty ? request.agent.name : "\(request.agent.name) · \(request.project)")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            Spacer(minLength: 4)
            if request.questions.count > 1, request.kind != .permission {
                Text("\(index + 1)/\(request.questions.count)").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
            }
            if store.requests.count > 1 {
                Text(T("대기 \(store.requests.count - 1)", "\(store.requests.count - 1) waiting")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(height: 16)
    }

    // MARK: 선택 질문

    private func question(_ q: AgentAsk.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(q.question).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: AgentAskPage.rowSpacing) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { _, option in
                    optionRow(option, picked: pickedState.wrappedValue.contains(option.label), multi: q.multiSelect) { choose(option.label, in: q) }
                }
            }
        }
    }

    private func optionRow(_ option: AgentAsk.Option, picked: Bool, multi: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if multi {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle").font(.system(size: 12))
                        .foregroundStyle(picked ? request.agent.tint : .white.opacity(0.4))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    if !option.detail.isEmpty {
                        Text(option.detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if confirmed == option.label { checkMark() }
            }
            .padding(.horizontal, 10)
            .frame(height: option.detail.isEmpty ? AgentAskPage.rowHeight : AgentAskPage.detailRowHeight)
            .background(Color.white.opacity(picked || confirmed == option.label ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(request.kind == .notice)
        .allowsHitTesting(confirmed == nil)
    }

    private func choose(_ label: String, in q: AgentAsk.Question) {
        if q.multiSelect {
            if pickedState.wrappedValue.contains(label) { pickedState.wrappedValue.remove(label) } else { pickedState.wrappedValue.insert(label) }
        } else {
            confirm(label) { next(q, answer: label) }
        }
    }

    /// 이 질문의 답을 적고 다음 질문으로. 마지막이면 모두 보낸다.
    private func next(_ q: AgentAsk.Question, answer: String) {
        answersState.wrappedValue[q.question] = answer
        if index + 1 < request.questions.count {
            pickedState.wrappedValue = []
            typedState.wrappedValue = ""
            indexState.wrappedValue = index + 1
        } else {
            store.answer(request, answers: answersState.wrappedValue)
        }
    }

    /// 여러 개 고르기·직접 입력의 보내기
    private func send() {
        if request.kind == .permission {
            guard !typed.isEmpty else { return }
            let message = typed
            return confirm("#send") { store.deny(request, message: message) }
        }
        guard let q = request.questions[safe: index] else { return }
        // 고른 순서가 아니라 선택지 순서로 잇는다
        var parts = q.options.map(\.label).filter(pickedState.wrappedValue.contains)
        if !typed.isEmpty { parts.append(typed) }
        guard !parts.isEmpty else { return }
        let answer = parts.joined(separator: ", ")
        confirm("#send") { next(q, answer: answer) }
    }

    // MARK: 실행 허락

    private var permission: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("\(request.tool) 실행을 허락할까요?", "Allow \(request.tool) to run?"))
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            if !request.detail.isEmpty {
                Text(request.detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.7)).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: AgentAskPage.rowSpacing) {
                decisionButton(T("허용", "Allow"), key: "#allow", primary: true) { store.allow(request) }
                decisionButton(T("거부", "Deny"), key: "#deny", primary: false) { store.deny(request, message: "") }
            }
        }
    }

    private func decisionButton(_ title: String, key: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button { confirm(key, then: action) } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                if confirmed == key { checkMark() }
            }
                .frame(maxWidth: .infinity).frame(height: AgentAskPage.rowHeight)
                .background(primary ? request.agent.tint.opacity(0.55) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(confirmed == nil)
    }

    // MARK: 아래 줄: 직접 입력 (Antigravity는 그 앱에서 답하기)

    @ViewBuilder
    private var footer: some View {
        if request.kind == .notice {
            Button { store.openHost() } label: {
                Text(T("Antigravity에서 답하기", "Answer in Antigravity")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(request.agent.tint.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            let multi = request.kind == .question && request.questions[safe: index]?.multiSelect == true
            let canSend = !typed.isEmpty || (multi && !pickedState.wrappedValue.isEmpty)
            HStack(spacing: 6) {
                AskTextField(text: typedState.wrappedValue,
                             placeholder: request.kind == .permission ? T("거부하고 다르게 지시하기", "Deny and say what to do instead") : T("직접 입력", "Type your own answer"),
                             onChange: { typedState.wrappedValue = $0 }, onSubmit: send)
                    .id("\(request.id)-\(index)")
                    .frame(height: 20)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button(action: send) {
                    if confirmed == "#send" {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
                            .foregroundStyle(.white, request.agent.tint)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                            .foregroundStyle(canSend ? request.agent.tint : .white.opacity(0.25))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend || confirmed != nil)
                .help(T("보내기", "Send"))
            }
        }
    }
}

/// 노치 안의 한 줄 입력 칸. 누르면 노치 창이 키보드를 받는다. 한글 조합 중 Return은 조합만 끝낸다.
struct AskTextField: NSViewRepresentable {
    var text: String
    var placeholder: String
    var onChange: (String) -> Void
    var onSubmit: () -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AskTextField
        init(_ parent: AskTextField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            parent.onChange(f.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            parent.onChange(textView.string)
            parent.onSubmit()
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = FocusTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.textColor = .white
        f.font = .systemFont(ofSize: 12)
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.35), .font: NSFont.systemFont(ofSize: 12)])
        f.delegate = context.coordinator
        f.stringValue = text
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.currentEditor() == nil, f.stringValue != text { f.stringValue = text }
    }

    private final class FocusTextField: NSTextField {
        override func mouseDown(with event: NSEvent) {
            window?.makeKey()
            super.mouseDown(with: event)
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
