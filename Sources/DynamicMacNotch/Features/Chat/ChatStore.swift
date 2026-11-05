import AppKit

/// 노치 채팅의 대화. 디스크에 저장하지 않고 메모리에만 둔다.
/// 페이지를 떠나고 일정 시간이 지나면 지운다 (잠깐 다른 페이지를 봐도 대화가 사라지지 않게).
/// 질문 중에는 노치를 닫아도 답변을 계속 받는다. 대기 중에는 타이머·네트워크가 돌지 않는다.
final class ChatStore: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: Int
        let role: ChatTurn.Role
        let text: String
        /// 완성된 답변의 표시용 글자 (질문은 nil)
        let rendered: AttributedString?
    }

    @Published private(set) var entries: [Entry] = []
    /// 받고 있는 답변
    @Published private(set) var partial = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var error: ChatError?
    /// 마지막 답변이 출력 한도에 걸려 잘렸는지
    @Published private(set) var truncated = false
    /// 입력 중인 글. 글자마다 화면을 다시 계산하지 않도록 @Published가 아니다.
    var draft = ""
    /// 입력 칸 바깥에서 글을 바꿀 때마다 늘어난다 (입력 칸이 이때만 내용을 다시 맞춘다)
    @Published private(set) var draftRevision = 0

    private let settings = AppSettings.shared
    private var nextID = 0
    private var task: Task<Void, Never>?
    /// 취소한 요청의 뒤늦은 이벤트를 무시하기 위한 번호
    private var generation = 0
    private var buffer = ""
    private var flushWork: DispatchWorkItem?
    private var visible = false
    private var clearWork: DispatchWorkItem?

    /// 화면 갱신 간격: 글자 조각마다 다시 그리지 않고 모아서 그린다
    private static let flushInterval: TimeInterval = 0.08
    private static let maxContextTurns = 12
    private static let maxContextCharacters = 20_000
    /// 페이지를 떠난 뒤 대화를 지우기까지
    private static let clearDelay: TimeInterval = 600

    // MARK: - 페이지 표시

    func setVisible(_ isVisible: Bool) {
        visible = isVisible
        clearWork?.cancel()
        clearWork = nil
        if !isVisible { scheduleClear() }
    }

    private func scheduleClear() {
        guard !visible, !isStreaming, !(entries.isEmpty && draft.isEmpty) else { return }
        let work = DispatchWorkItem { [weak self] in self?.newChat() }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clearDelay, execute: work)
    }

    // MARK: - 보내기·중지

    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !question.isEmpty else { return }
        let service = settings.chatService
        let model = settings.chatModel(for: service).trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else {
            error = .noModel
            return
        }
        setDraft("")
        append(.user, question)
        let turns = contextTurns()
        error = nil
        truncated = false
        isStreaming = true
        generation &+= 1
        let current = generation
        // 키체인 읽기는 시간이 걸릴 수 있어 메인 스레드 밖에서 한다
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let key = Self.apiKey(for: service)
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                guard let key, !key.isEmpty else {
                    self.fail(.missingKey)
                    return
                }
                self.task = ChatClient.stream(service: service, model: model, key: key, turns: turns) { [weak self] event in
                    DispatchQueue.main.async { self?.handle(event, generation: current) }
                }
            }
        }
    }

    private static func apiKey(for service: ChatService) -> String? {
        #if DEV
        if let key = ProcessInfo.processInfo.environment["DMN_CHAT_KEY"] { return key }   // 개발용: 키체인 없이 가짜 서버로 시험
        #endif
        return ChatKeychain.read(for: service)
    }

    /// 지금까지 받은 답변은 남기고 멈춘다
    func stop() {
        guard isStreaming else { return }
        cancelRequest()
        flush()
        isStreaming = false
        keepPartial()
        scheduleClear()
    }

    func newChat() {
        cancelRequest()
        buffer = ""
        partial = ""
        isStreaming = false
        entries = []
        error = nil
        truncated = false
        setDraft("")
        clearWork?.cancel()
        clearWork = nil
    }

    func copyLastAnswer() {
        guard let text = lastAnswer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var lastAnswer: String? { entries.last { $0.role == .assistant }?.text }

    private func cancelRequest() {
        generation &+= 1
        task?.cancel()
        task = nil
        flushWork?.cancel()
        flushWork = nil
    }

    // MARK: - 스트림

    private func handle(_ event: ChatEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .delta(let text):
            buffer += text
            scheduleFlush()
        case .done(let wasTruncated):
            flush()
            truncated = wasTruncated
            finish()
        case .failed(let failure):
            flush()
            fail(failure)
        }
    }

    private func scheduleFlush() {
        guard flushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval, execute: work)
    }

    private func flush() {
        flushWork?.cancel()
        flushWork = nil
        guard !buffer.isEmpty else { return }
        partial += buffer
        buffer = ""
    }

    private func finish() {
        task = nil
        isStreaming = false
        keepPartial()
        scheduleClear()
    }

    private func fail(_ failure: ChatError) {
        task = nil
        isStreaming = false
        if partial.isEmpty, let last = entries.last, last.role == .user {
            // 답변이 하나도 오지 않았으면 질문을 입력 칸으로 되돌려 다시 보낼 수 있게 한다
            entries.removeLast()
            if draft.isEmpty { setDraft(last.text) }
        } else {
            keepPartial()
        }
        error = failure
        scheduleClear()
    }

    private func setDraft(_ text: String) {
        draft = text
        draftRevision &+= 1
    }

    private func keepPartial() {
        guard !partial.isEmpty else { return }
        append(.assistant, partial)
        partial = ""
    }

    private func append(_ role: ChatTurn.Role, _ text: String) {
        nextID += 1
        entries.append(Entry(id: nextID, role: role, text: text, rendered: role == .assistant ? Self.render(text) : nil))
    }

    /// 최근 대화만 보낸다 (비용과 메모리를 함께 줄인다). 질문으로 시작해야 한다.
    private func contextTurns() -> [ChatTurn] {
        var turns: [ChatTurn] = []
        var characters = 0
        for entry in entries.reversed() {
            characters += entry.text.count
            if !turns.isEmpty, turns.count >= Self.maxContextTurns || characters > Self.maxContextCharacters { break }
            turns.append(ChatTurn(role: entry.role, text: entry.text))
        }
        while turns.last?.role == .assistant { turns.removeLast() }
        return turns.reversed()
    }

    /// 굵게·기울임·코드 같은 인라인 서식만 적용한다.
    /// 모델이 쓴 링크는 표시 글자와 실제 주소가 다를 수 있으므로 누를 수 없게 지운다.
    private static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in attributed.runs where run.link != nil { attributed[run.range].link = nil }
        return attributed
    }
}
