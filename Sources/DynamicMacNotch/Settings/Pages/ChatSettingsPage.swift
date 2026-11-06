import AppKit
import SwiftUI

/// 설정 → AI 채팅: 표시, 서비스별 모델과 API 키, 답변, 저장된 대화.
struct ChatSettingsPage: View {
    @ObservedObject var settings: AppSettings

    private enum TestState: Equatable {
        case idle, testing, passed
        case failed(ChatError)
    }

    private let keyInputState = State(initialValue: "")
    /// 화면을 그릴 때마다 키체인을 읽지 않도록 기억해 둔다 (지침을 입력하면 글자마다 다시 그려진다)
    private let hasKeyState = State(initialValue: false)
    private let usageState = State(initialValue: (count: 0, bytes: Int64(0)))
    private let confirmClearState = State(initialValue: false)
    private let testState = State(initialValue: TestState.idle)
    private let saveFailedState = State(initialValue: false)
    /// 받아 온 모델 목록 (설정 창이 열린 동안만 기억한다)
    private let fetchedState = State(initialValue: [ChatService: [ChatModelOption]]())
    private let fetchingState = State(initialValue: false)
    private let fetchErrorState = State(initialValue: ChatError?.none)

    private var keyInput: Binding<String> { keyInputState.projectedValue }
    private var test: TestState {
        get { testState.wrappedValue }
        nonmutating set { testState.wrappedValue = newValue }
    }

    private var service: ChatService { settings.chatService }
    private var model: String { settings.chatModel(for: service) }

    var body: some View {
        let hasKey = hasKeyState.wrappedValue
        Form {
            SettingsSection(SectionTitle.show, footer: T("입력한 질문, 최근 대화, 직접 첨부한 파일이 아래에서 고른 회사로 전송됩니다. 클립보드·화면·파일을 앱이 알아서 보내지는 않습니다. '처음 화면'을 골라도 지난 채팅은 목록에 남고, 답변 완료 알림을 누르면 그 답변이 열립니다.",
                                                        "Your questions, recent messages and files you attach are sent to the company you choose below. The clipboard, screen and files are never sent on their own. With New Chat Screen, past chats stay in the list, and clicking an Answer Ready alert still opens that answer.")) {
                HomePageToggle(settings: settings, key: "chat", title: T("홈에 AI 채팅 페이지 표시", "Show AI Chat in Home"))
                SegmentedChoice(T("다시 열 때 보여 줄 화면", "When reopened, show"), selection: $settings.chatReopen)
            }
            Section {
                Picker(T("서비스", "Service"), selection: $settings.chatService) {
                    ForEach(ChatService.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { Text(T("사용할 서비스", "Service to Use")) }

            Section {
                LabeledContent(T("모델", "Model")) {
                    HStack(spacing: 6) {
                        TextField("", text: modelBinding, prompt: Text(T("모델 ID", "Model ID")))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .labelsHidden()
                        if let tier = options.first(where: { $0.id == model })?.tier ?? ChatModelTier.of(model) {
                            Text(tier.label).font(.caption).foregroundStyle(.secondary).fixedSize()
                        }
                        if !options.isEmpty || ChatModels.canFetch(service) { modelMenu.fixedSize() }
                    }
                }
                if fetchingState.wrappedValue || fetchErrorState.wrappedValue != nil {
                    HStack(spacing: 6) {
                        if fetchingState.wrappedValue {
                            ProgressView().controlSize(.small)
                            Text(T("모델 목록을 불러오는 중", "Loading models")).foregroundStyle(.secondary)
                        } else if let error = fetchErrorState.wrappedValue {
                            Text(T("모델 목록을 불러오지 못했습니다: \(error.message)", "Couldn't load models: \(error.message)")).foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                }
            } header: { Text(T("\(service.name) 모델", "\(service.name) Model")) } footer: {
                footnote(service == .claude
                         ? T("서비스마다 모델을 따로 기억합니다. 답변 속도와 요금은 모델마다 다르며, 기본값인 Haiku가 가장 빠르고 저렴합니다.",
                             "Each service remembers its own model. Speed and price vary by model; the default, Haiku, is the fastest and cheapest.")
                         : T("서비스마다 모델을 따로 기억합니다. 저장한 키로 쓸 수 있는 모델을 불러오며, 직접 입력해도 됩니다. 빠름·균형·고성능은 모델 이름과 설명으로 판단한 참고용이고, 판단할 수 없는 모델은 '기타'에 넣습니다.",
                             "Each service remembers its own model. Models available to your saved key are loaded here, or you can type an ID. Fast, Balanced and Most Capable are estimated from model names and descriptions; models that can't be judged are under Other."))
            }

            Section {
                LabeledContent(T("상태", "Status")) {
                    HStack(spacing: 8) {
                        Text(hasKey ? T("저장됨", "Saved") : T("저장된 키 없음", "No key saved"))
                            .foregroundStyle(hasKey ? .green : .secondary)
                        if hasKey {
                            Button(T("삭제", "Delete")) {
                                ChatKeychain.delete(for: service)
                                keysChanged()
                            }
                        }
                    }
                }
                LabeledContent(hasKey ? T("키 바꾸기", "Replace Key") : T("API 키", "API Key")) {
                    HStack(spacing: 6) {
                        SecureField("", text: keyInput, prompt: Text(T("키 붙여넣기", "Paste key")))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .labelsHidden()
                        Button(T("저장", "Save"), action: saveKey)
                            .disabled(trimmedKey.isEmpty)
                    }
                }
                if saveFailedState.wrappedValue {
                    Text(T("키체인에 저장하지 못했습니다", "Couldn't save to the Keychain")).foregroundStyle(.red)
                }
                LabeledContent(T("연결 테스트", "Connection Test")) {
                    HStack(spacing: 8) {
                        testResult
                        Button(T("테스트", "Test"), action: runTest)
                            .disabled(!hasKey || model.isEmpty || test == .testing)
                    }
                }
                Link(T("\(service.company) API 키 발급 페이지", "Get an API key from \(service.company)"), destination: service.keysURL)
            } header: { Text(T("\(service.company) API 키", "\(service.company) API Key")) } footer: {
                footnote(T("키는 이 Mac의 키체인에만 저장되고, 질문할 때 \(service.company)에만 전송됩니다. API 사용 요금은 월정액 구독과 별도로 \(service.company)가 키 주인에게 청구합니다. 연결 테스트는 키와 모델만 확인하며 요금이 들지 않습니다.",
                           "Your key is stored only in this Mac's Keychain and is sent only to \(service.company) when you ask a question. API usage is billed to the key's owner by \(service.company), separately from any subscription. The connection test only checks the key and model, at no cost."))
            }
            SettingsSection(T("답변", "Answers"), footer: T("웹 검색은 각 서비스의 검색 도구를 쓰며 별도 요금이 붙을 수 있습니다. 답변 지침은 모든 서비스의 답변에 적용되며, 질문할 때마다 고른 회사로 함께 전송됩니다. 최대 \(AppSettings.chatInstructionsLimit)자입니다 (지금 \(settings.chatInstructions.count)자).",
                                                           "Web search uses each service's search tool and may cost extra. Answer instructions apply to every service and are sent to the company you choose with each question. Up to \(AppSettings.chatInstructionsLimit) characters (now \(settings.chatInstructions.count)).")) {
                Toggle(T("필요할 때만 웹 검색 (최근 소식, 확실하지 않은 내용)", "Use web search only when needed (recent or uncertain topics)"), isOn: $settings.chatWebSearch)
                ZStack(alignment: .topLeading) {
                    if settings.chatInstructions.isEmpty {
                        Text(T("답변 지침 예: 항상 존댓말로 짧게 답해 줘. 코드는 Swift로 보여 줘.", "Answer instructions, e.g. Keep answers short. Show code in Swift."))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: instructionsBinding)
                        .scrollContentBackground(.hidden)
                        .frame(height: 84)
                }
            }
            SettingsSection(T("저장된 대화", "Saved Conversations"), footer: T("대화와 첨부 파일은 메모처럼 이 Mac에 암호화 없이 저장되며, 노치의 채팅 목록에서 하나씩 지울 수도 있습니다. 모두 삭제해도 메모·설정·API 키는 지우지 않습니다.",
                                                                          "Conversations and attachments are saved unencrypted on this Mac like memos, and you can delete them one by one from the chat list in the notch. Delete All keeps memos, settings and API keys.")) {
                LabeledContent(T("저장 용량", "Storage")) {
                    HStack(spacing: 8) {
                        let usage = usageState.wrappedValue
                        Text(T("\(usage.count)개 · \(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))",
                               "\(usage.count) · \(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))"))
                            .foregroundStyle(.secondary)
                        Button(T("모두 삭제…", "Delete All…")) {
                            refreshUsage()   // 노치에서 대화하는 동안 설정 창은 활성 상태 그대로라 개수가 낡을 수 있다
                            confirmClearState.wrappedValue = true
                        }
                        .disabled(usageState.wrappedValue.count == 0)
                    }
                }
            }
            Section {
                DisclosureGroup(T("첨부 파일 안내", "About Attachments")) {
                    footnote(T("이미지 \(ChatAttachLimit.images)장, PDF 1개(10MB·\(ChatAttachLimit.pdfPages)쪽), 텍스트 파일(200KB), 워드 파일을 질문에 첨부할 수 있습니다. 클립 버튼, ⌘V, 파일 끌어놓기로 붙입니다.",
                               "You can attach up to \(ChatAttachLimit.images) images, one PDF (10 MB, \(ChatAttachLimit.pdfPages) pages), text files (200 KB) and Word files to a question, using the paperclip, ⌘V or drag and drop."))
                    footnote(T("앱을 다시 시작해도 후속 질문에 쓸 수 있습니다. 이미지는 긴 변 \(ChatAttachLimit.imageLongEdge)픽셀로 줄이고 위치 정보를 지우며, 워드 파일은 글자만 저장합니다.",
                               "Follow-up questions can use them even after a restart. Images are reduced to \(ChatAttachLimit.imageLongEdge) pixels on the long edge with location data removed, and Word files keep only their text."))
                    footnote(T("후속 질문에서는 파일을 매번 보내지 않습니다. 질문이 파일 이름이나 '이 사진', '첨부' 같은 말로 파일을 가리키면 함께 보내고, 그 밖에는 파일 이름만 알려서 AI가 꼭 필요하다고 판단할 때만 다시 보냅니다. 다시 보낸 파일은 질문 아래에 ↻로 표시되며, 그만큼 토큰(요금 또는 구독 한도)을 씁니다.",
                               "Follow-up questions don't always resend files. A file is sent again when the question points to it, by its name or words like \"this photo\" or \"attached\". Otherwise the AI only sees the file names and asks for a file when it really needs it. Files sent again are marked ↻ under the question and use tokens (billing or subscription limits)."))
                }
            }
            PreviewSection([(.chatDone, T("답변 완료 알림", "Answer Ready Alert"))])
        }
        .settingsForm()
        .alert(T("저장된 대화를 모두 삭제할까요?", "Delete all saved conversations?"), isPresented: confirmClearState.projectedValue) {
            Button(T("모두 삭제", "Delete All"), role: .destructive, action: clearStoredChats)
            Button(T("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(T("대화 \(usageState.wrappedValue.count)개가 삭제되며 되돌릴 수 없습니다.", "\(usageState.wrappedValue.count) conversations will be deleted. This can't be undone."))
        }
        .onChange(of: settings.chatService) { _, _ in
            keyInput.wrappedValue = ""
            saveFailedState.wrappedValue = false
            test = .idle
            fetchErrorState.wrappedValue = nil
            refreshHasKey()
            loadModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshUsage() }
        .onAppear {
            #if DEV
            // 개발용: 시험 이벤트가 앱에 닿지 않으므로 확인 창과 삭제를 직접 실행한다
            if ProcessInfo.processInfo.environment["DMN_CLEAR_TEST"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { confirmClearState.wrappedValue = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    confirmClearState.wrappedValue = false
                    clearStoredChats()
                }
            }
            #endif
            refreshUsage()
            refreshHasKey()
            loadModels()
        }
    }

    // MARK: - 모델 목록

    private var options: [ChatModelOption] { fetchedState.wrappedValue[service] ?? ChatModels.presets(service) }

    private var modelMenu: some View {
        Menu(T("선택", "Choose")) {
            ForEach(ChatModelTier.allCases) { tier in
                let group = options.filter { $0.tier == tier }
                if !group.isEmpty {
                    Section(tier.label) { modelButtons(group) }
                }
            }
            let others = options.filter { $0.tier == nil }
            if !others.isEmpty {
                Section(T("기타", "Other")) { modelButtons(others) }
            }
            if ChatModels.canFetch(service) {
                Divider()
                Button(T("목록 새로고침", "Reload List")) { loadModels(force: true) }
            }
        }
    }

    private func modelButtons(_ group: [ChatModelOption]) -> some View {
        ForEach(group) { option in
            Button(option.id) {
                settings.setChatModel(option.id, for: service)
                test = .idle
            }
        }
    }

    /// 키가 있으면 쓸 수 있는 모델을 받아 온다 (토큰을 쓰지 않음)
    private func loadModels(force: Bool = false) {
        let service = service
        guard ChatModels.canFetch(service), force || fetchedState.wrappedValue[service] == nil, ChatKeychain.has(for: service) else { return }
        fetchingState.wrappedValue = true
        fetchErrorState.wrappedValue = nil
        Task.detached(priority: .userInitiated) {
            let result: Result<[ChatModelOption], ChatError>
            if let key = ChatKeychain.read(for: service) {
                result = await ChatModels.fetch(service: service, key: key)
            } else {
                result = .failure(.missingKey)
            }
            await MainActor.run {
                fetchingState.wrappedValue = false
                switch result {
                case .success(let list): fetchedState.wrappedValue[service] = list
                case .failure(let error):
                    // 그사이 서비스를 바꿨으면 다른 서비스의 오류를 보여 주지 않는다
                    if settings.chatService == service { fetchErrorState.wrappedValue = error }
                }
            }
        }
    }

    private var instructionsBinding: Binding<String> {
        Binding(get: { settings.chatInstructions },
                set: { settings.chatInstructions = String($0.prefix(AppSettings.chatInstructionsLimit)) })
    }

    private func refreshUsage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let usage = ChatStore.storedUsage()
            DispatchQueue.main.async { usageState.wrappedValue = usage }
        }
    }

    private func clearStoredChats() {
        DispatchQueue.global(qos: .userInitiated).async {
            ChatStore.deleteAllStored()
            DispatchQueue.main.async {
                Helper.sendToMain("chatscleared")
                refreshUsage()
                // 그 순간 끝난 답변이 다시 저장되었으면 남은 개수가 보이도록 한 번 더 센다
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refreshUsage() }
            }
        }
    }

    private func refreshHasKey() { hasKeyState.wrappedValue = ChatKeychain.has(for: service) }

    private var modelBinding: Binding<String> {
        Binding(get: { settings.chatModel(for: service) },
                set: {
                    // 입력 칸이 포커스를 잃을 때도 불린다: 그대로면 기본 모델을 저장값으로 굳히지 않는다
                    guard $0 != settings.chatModel(for: service) else { return }
                    settings.setChatModel($0, for: service)
                    test = .idle
                })
    }

    private var trimmedKey: String { keyInput.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder
    private var testResult: some View {
        switch test {
        case .idle: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .passed: Text(T("연결됨", "Connected")).foregroundStyle(.green)
        case .failed(let error): Text(error.message).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func saveKey() {
        let saved = ChatKeychain.save(trimmedKey, for: service)
        saveFailedState.wrappedValue = !saved
        if saved { keyInput.wrappedValue = "" }   // 입력 칸에 키를 남기지 않는다
        keysChanged()
    }

    private func keysChanged() {
        test = .idle
        refreshHasKey()
        // 키가 바뀌면 쓸 수 있는 모델도 달라진다
        fetchedState.wrappedValue[service] = nil
        fetchErrorState.wrappedValue = nil
        loadModels()
    }

    private func runTest() {
        let service = service, model = model
        test = .testing
        Task.detached(priority: .userInitiated) {
            guard let key = ChatKeychain.read(for: service) else {
                await MainActor.run { test = .failed(.unauthorized) }
                return
            }
            let error = await ChatClient.test(service: service, model: model, key: key)
            await MainActor.run {
                // 그사이 서비스를 바꿨으면 결과를 버린다
                guard settings.chatService == service else { return }
                test = error.map(TestState.failed) ?? .passed
            }
        }
    }
}
