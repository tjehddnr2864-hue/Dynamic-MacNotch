import SwiftUI

/// 설정 → AI 채팅: 서비스, 서비스별 모델과 API 키, 연결 테스트.
struct ChatSettingsPage: View {
    @ObservedObject var settings: AppSettings

    private enum TestState: Equatable {
        case idle, testing, passed
        case failed(ChatError)
    }

    private let keyInputState = State(initialValue: "")
    private let refreshState = State(initialValue: 0)
    private let testState = State(initialValue: TestState.idle)
    private let saveFailedState = State(initialValue: false)

    private var keyInput: Binding<String> { keyInputState.projectedValue }
    private var test: TestState {
        get { testState.wrappedValue }
        nonmutating set { testState.wrappedValue = newValue }
    }

    private var service: ChatService { settings.chatService }
    private var model: String { settings.chatModel(for: service) }

    var body: some View {
        let _ = refreshState.wrappedValue   // 키를 저장·삭제한 뒤 상태를 다시 읽는다
        let hasKey = ChatKeychain.has(for: service)
        Form {
            Section {
                Toggle(T("노치 홈에 AI 채팅 페이지 표시", "Show the AI Chat page in the notch's Home"), isOn: $settings.chatEnabled)
                Toggle(T("모르는 내용과 최근 소식은 웹 검색으로 답변", "Use web search for recent or unknown topics"), isOn: $settings.chatWebSearch)
                Picker(T("다시 열 때 보여 줄 화면", "When Reopened, Show"), selection: $settings.chatReopen) {
                    ForEach(ChatReopen.allCases) { Text($0.label).tag($0) }
                }
            } header: { Text(T("표시", "Show")) } footer: {
                footnote(T("입력한 질문과 최근 대화가 아래에서 고른 회사로 전송됩니다. 클립보드·화면·파일은 보내지 않습니다. 채팅 내용은 메모처럼 이 Mac에 저장되며, 노치의 채팅 목록에서 삭제할 수 있습니다. '처음 화면'을 골라도 지난 채팅은 목록에 남고, 답변 완료 알림을 누르면 그 답변이 열립니다. 웹 검색은 각 서비스의 검색 도구를 쓰며 API 키 방식에서는 별도 요금이 붙을 수 있습니다.",
                           "Your questions and recent messages are sent to the company you choose below. The clipboard, screen and files are never sent. Chats are saved on this Mac like memos, and you can delete them from the chat list in the notch. With New Chat Screen, past chats stay in the list, and clicking an Answer Ready alert still opens that answer. Web search uses each service's search tool and may cost extra with an API key."))
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
                        if !service.modelPresets.isEmpty {
                            Menu(T("선택", "Choose")) {
                                ForEach(service.modelPresets, id: \.id) { preset in
                                    Button(preset.label) { settings.setChatModel(preset.id, for: service) }
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
            } header: { Text(T("\(service.name) 모델", "\(service.name) Model")) } footer: {
                footnote(service == .claude
                         ? T("서비스마다 모델을 따로 기억합니다. 답변 속도와 요금은 모델마다 다르며, 기본값인 Haiku가 가장 빠르고 저렴합니다.",
                             "Each service remembers its own model. Speed and price vary by model; the default, Haiku, is the fastest and cheapest.")
                         : T("서비스마다 모델을 따로 기억합니다. \(service.company) 문서의 모델 ID를 입력해 주세요.",
                             "Each service remembers its own model. Enter a model ID from \(service.company)'s documentation."))
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
        }
        .settingsForm()
        .onChange(of: settings.chatService) { _, _ in
            keyInput.wrappedValue = ""
            saveFailedState.wrappedValue = false
            test = .idle
        }
    }

    private var modelBinding: Binding<String> {
        Binding(get: { settings.chatModel(for: service) },
                set: {
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
        refreshState.wrappedValue += 1
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

    private func footnote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
