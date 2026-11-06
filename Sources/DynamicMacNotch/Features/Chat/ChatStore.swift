import AppKit

/// 저장되는 채팅 한 개 (파일 하나)
struct ChatRecord: Codable {
    struct Message: Codable {
        var role: String
        var text: String
    }
    var id: UUID
    var title: String
    /// 사용자가 직접 지은 이름인지 (아니면 첫 질문으로 자동으로 붙인다)
    var named: Bool
    var messages: [Message]
    var updated: Date
}

/// 목록에 보일 요약 (대화 내용은 읽어 두지 않는다)
struct ChatSummary: Identifiable, Equatable {
    var id: UUID
    var title: String
    var updated: Date
}

/// 노치 채팅. 메모처럼 채팅마다 파일 하나로 저장하고, 페이지가 보이는 동안(또는 답변을 기다리는 동안)만 메모리에 올린다.
/// 답변은 다 받은 뒤 한 번에 보여 준다. 질문 중에는 노치를 닫아도 계속 받고, 끝나면 알림으로 알린다.
/// 대기 중에는 타이머·네트워크가 돌지 않는다.
final class ChatStore: ObservableObject {
    struct Entry: Identifiable {
        let id: Int
        let role: ChatTurn.Role
        let text: String
        /// 답변의 표시용 글자 (질문은 nil)
        let rendered: NSAttributedString?
    }

    @Published private(set) var currentID = UUID()
    @Published private(set) var title = ""
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var error: ChatError?
    /// 마지막 답변이 출력 한도에 걸려 잘렸는지
    @Published private(set) var truncated = false
    @Published private(set) var showList = false
    @Published private(set) var summaries: [ChatSummary] = []
    /// 입력 중인 글. 글자마다 화면을 다시 계산하지 않도록 @Published가 아니다.
    var draft = ""
    /// 입력 칸 바깥에서 글을 바꿀 때마다 늘어난다 (입력 칸이 이때만 내용을 다시 맞춘다)
    @Published private(set) var draftRevision = 0
    /// 페이지가 안 보일 때 답변이 끝나면 불린다 (실패면 그 오류, 채팅 이름)
    var onFinishedInBackground: ((ChatError?, String) -> Void)?

    /// 대화·오류·목록을 보여 줄 큰 노치인지. 입력만 있거나 생각 중이면 작은 노치다.
    var isLarge: Bool { !isStreaming && (!entries.isEmpty || error != nil || showList) }

    private let settings = AppSettings.shared
    private var named = false
    private var loaded = false
    private var nextEntryID = 0
    private var task: Task<Void, Never>?
    /// 취소한 요청의 뒤늦은 이벤트를 무시하기 위한 번호
    private var generation = 0
    private var answer = ""
    private var visible = false
    private var opensAnswerNext = false
    private var unloadWork: DispatchWorkItem?
    private var titleSaveWork: DispatchWorkItem?

    /// 답변 칸의 폭 (수식을 이보다 넓게 그리지 않는다)
    private static let answerWidth: CGFloat = 330
    private static let maxContextTurns = 12
    private static let maxContextCharacters = 20_000
    /// 페이지가 닫힌 뒤 메모리에서 내리기까지
    private static let unloadDelay: TimeInterval = 5
    private static let currentKey: String = {
        #if DEV
        if ProcessInfo.processInfo.environment["DMN_CHAT_FOLDER"] != nil { return "chatCurrentID.test" }
        #endif
        return "chatCurrentID"
    }()

    static var folder: URL {
        #if DEV
        // 개발용: 시험 채팅이 실제 채팅에 섞이지 않게 다른 폴더를 쓴다
        if let path = ProcessInfo.processInfo.environment["DMN_CHAT_FOLDER"] { return URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DynamicMacNotch/Chats", isDirectory: true)
    }

    private static func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    // MARK: - 페이지 열림·닫힘

    func pageAppeared() {
        visible = true
        unloadWork?.cancel()
        unloadWork = nil
        let keepAnswer = opensAnswerNext
        opensAnswerNext = false
        if settings.chatReopen == .fresh, !keepAnswer, !isStreaming {
            // 처음 화면: 입력 칸만. 지난 채팅은 파일에 남아 있어 목록에서 열 수 있다 (쓰던 글은 그대로 둔다)
            saveTitleNow()
            startEmpty()
            loaded = true
            showList = false
            summaries = []
            error = nil
            truncated = false
            return
        }
        if !loaded { loadCurrent() }
        if showList { reloadList() }
    }

    /// 답변 완료 알림을 눌러 페이지를 열 때: 설정과 상관없이 그 답변을 보여 준다
    func openAnswerNext() { opensAnswerNext = true }

    func pageDisappeared() {
        visible = false
        saveTitleNow()
        scheduleUnload()
    }

    private func scheduleUnload() {
        unloadWork?.cancel()
        unloadWork = nil
        guard !visible, !isStreaming, loaded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.visible, !self.isStreaming else { return }
            self.loaded = false
            self.entries = []
            self.summaries = []
            self.unloadWork = nil
            Self.returnMemory()
        }
        unloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unloadDelay, execute: work)
    }

    /// 지난 답변이 실제로 해제되게 한다. 메인 스레드의 자동 해제 풀은 다음 이벤트에야 비워지는데,
    /// 마우스·키 입력이 없으면 그때까지 렌더링한 답변과 이미지를 붙들고 있으므로 빈 이벤트를 보낸다.
    private static func returnMemory() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(event, atStart: false)
            }
            MemoryTrim.soon()
            MemoryGuard.shared.checkSoon()
        }
    }

    private func loadCurrent() {
        loaded = true
        let saved = UserDefaults.standard.string(forKey: Self.currentKey).flatMap(UUID.init)
        if let record = saved.flatMap(Self.read) {
            apply(record)
        } else if !entries.isEmpty || saved != currentID {
            startEmpty()
        }
    }

    private func apply(_ record: ChatRecord) {
        currentID = record.id
        title = record.title
        named = record.named
        entries = []
        for message in record.messages {
            append(message.role == "user" ? .user : .assistant, message.text)
        }
    }

    private func startEmpty() {
        currentID = UUID()
        title = ""
        named = false
        entries = []
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
        if !named, title.isEmpty { title = Self.automaticTitle(question) }
        let turns = contextTurns()
        save()
        error = nil
        truncated = false
        answer = ""
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
                self.task = ChatClient.stream(service: service, model: model, key: key, turns: turns, search: self.settings.chatWebSearch) { [weak self] event in
                    DispatchQueue.main.async { self?.handle(event, generation: current) }
                }
            }
        }
    }

    private static func apiKey(for service: ChatService) -> String? {
        ChatKeychain.read(for: service)
    }

    private static func automaticTitle(_ question: String) -> String {
        let line = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? question
        return String(line.prefix(30))
    }

    /// 지금까지 받은 답변이 있으면 남기고 멈춘다
    func stop() {
        guard isStreaming else { return }
        cancelRequest()
        isStreaming = false
        keepAnswer()
        save()
        scheduleUnload()
    }

    private func cancelRequest() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    private func handle(_ event: ChatEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .delta(let text):
            answer += text
        case .done(let wasTruncated):
            truncated = wasTruncated
            task = nil
            isStreaming = false
            keepAnswer()
            save()
            finished(nil)
        case .failed(let failure):
            fail(failure)
        }
    }

    private func fail(_ failure: ChatError) {
        task = nil
        isStreaming = false
        if answer.isEmpty, let last = entries.last, last.role == .user {
            // 답변이 하나도 오지 않았으면 질문을 입력 칸으로 되돌려 다시 보낼 수 있게 한다
            entries.removeLast()
            if draft.isEmpty { setDraft(last.text) }
            if entries.isEmpty, !named { title = "" }
        } else {
            keepAnswer()
        }
        error = failure
        save()
        finished(failure)
    }

    private func finished(_ failure: ChatError?) {
        if !visible { onFinishedInBackground?(failure, title) }
        scheduleUnload()
    }

    private func setDraft(_ text: String) {
        draft = text
        draftRevision &+= 1
    }

    private func keepAnswer() {
        guard !answer.isEmpty else { return }
        append(.assistant, answer)
        answer = ""
    }

    private func append(_ role: ChatTurn.Role, _ text: String) {
        nextEntryID += 1
        entries.append(Entry(id: nextEntryID, role: role, text: text, rendered: role == .assistant ? ChatMarkdown.render(text, maxWidth: Self.answerWidth) : nil))
    }

    /// 최근 대화만 보낸다 (비용을 줄인다). 질문으로 시작해야 한다.
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

    // MARK: - 이름·새 채팅·불러오기·삭제

    func setTitle(_ newTitle: String) {
        guard newTitle != title else { return }
        title = newTitle
        named = !newTitle.trimmingCharacters(in: .whitespaces).isEmpty
        titleSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveTitleNow() }
        titleSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func saveTitleNow() {
        guard titleSaveWork != nil else { return }
        titleSaveWork?.cancel()
        titleSaveWork = nil
        save()
    }

    func newChat() {
        guard !isStreaming else { return }
        saveTitleNow()
        startEmpty()
        error = nil
        truncated = false
        setDraft("")
        UserDefaults.standard.removeObject(forKey: Self.currentKey)
    }

    func open(_ id: UUID) {
        guard !isStreaming else { return }
        showList = false
        summaries = []
        guard id != currentID else { return }
        saveTitleNow()
        guard let record = Self.read(id) else {
            reloadList()
            return
        }
        apply(record)
        error = nil
        truncated = false
        UserDefaults.standard.set(id.uuidString, forKey: Self.currentKey)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.file(id))
        if id == currentID, !isStreaming {
            titleSaveWork?.cancel()
            titleSaveWork = nil
            newChat()
        }
        summaries.removeAll { $0.id == id }
    }

    /// 설정에서 저장된 대화를 모두 지운 뒤 불린다. 알림은 보낸 쪽을 확인할 수 없으므로,
    /// 지금 채팅의 파일이 실제로 사라졌을 때만 메모리에서 지운다 (다른 프로그램이 알림만 보내서는 지워지지 않는다).
    func storedChatsCleared() {
        if showList { reloadList() }
        guard !FileManager.default.fileExists(atPath: Self.file(currentID).path) else { return }
        UserDefaults.standard.removeObject(forKey: Self.currentKey)
        guard !entries.isEmpty || isStreaming else { return }
        cancelRequest()
        isStreaming = false
        answer = ""
        titleSaveWork?.cancel()
        titleSaveWork = nil
        opensAnswerNext = false
        startEmpty()
        setDraft("")
        error = nil
        truncated = false
    }

    /// 저장된 대화의 개수와 크기 (설정 화면용. 내용은 읽지 않는다)
    static func storedUsage() -> (count: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let chats = files.filter { $0.pathExtension == "json" }
        let bytes = chats.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return (chats.count, bytes)
    }

    /// 저장된 대화 파일을 모두 지운다 (폴더 안의 .json만)
    static func deleteAllStored() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" { try? FileManager.default.removeItem(at: file) }
    }

    func toggleList() {
        showList.toggle()
        if showList { reloadList() } else { summaries = [] }
    }

    /// 파일을 모두 읽어야 하므로 메인 스레드 밖에서 한다
    private func reloadList() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = Self.loadSummaries()
            DispatchQueue.main.async {
                guard let self, self.showList else { return }
                self.summaries = list
            }
        }
    }

    // MARK: - 파일

    private func save() {
        // 질문이 없는 채팅은 남기지 않는다 (답을 못 받고 첫 질문을 되돌린 경우 포함)
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: Self.file(currentID))
            summaries.removeAll { $0.id == currentID }
            return
        }
        let now = Date()
        let record = ChatRecord(id: currentID, title: title, named: named,
                                messages: entries.map { .init(role: $0.role.rawValue, text: $0.text) }, updated: now)
        // 내 대화이므로 폴더를 나만 읽을 수 있게 만든다
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.folder.path)   // 이미 있던 폴더도
        if let data = try? JSONEncoder().encode(record), (try? data.write(to: Self.file(currentID), options: .atomic)) != nil {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file(currentID).path)
        }
        UserDefaults.standard.set(currentID.uuidString, forKey: Self.currentKey)
        if showList {
            summaries.removeAll { $0.id == currentID }
            summaries.insert(ChatSummary(id: currentID, title: title, updated: now), at: 0)
        }
    }

    private static func read(_ id: UUID) -> ChatRecord? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode(ChatRecord.self, from: data)
    }

    private static func loadSummaries() -> [ChatSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url -> ChatSummary? in
                guard let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(ChatRecord.self, from: data) else { return nil }
                return ChatSummary(id: r.id, title: r.title, updated: r.updated)
            }
            .sorted { $0.updated > $1.updated }
    }

    // MARK: - 알림

    /// 답변 완료 알림. 누르면 그 채팅이 열린다.
    static func finishedActivity(failure: ChatError?, title: String) -> NotchActivity {
        NotchActivity(kind: .chat, priority: ActivityPriority.info, presentation: .detail, duration: 8,
                      symbol: failure == nil ? "bubble.left.and.text.bubble.right.fill" : "exclamationmark.bubble.fill",
                      tint: failure == nil ? .blue : .orange,
                      value: failure == nil ? .check : .none,
                      title: failure == nil ? T("답변 완료", "Answer Ready") : T("답변 실패", "Answer Failed"),
                      subtitle: failure?.message ?? (title.isEmpty ? T("AI 채팅", "AI Chat") : title))
    }
}
