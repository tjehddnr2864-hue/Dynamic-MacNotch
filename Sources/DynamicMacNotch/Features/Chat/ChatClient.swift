import Foundation

struct ChatTurn: Equatable {
    enum Role: String { case user, assistant }
    var role: Role
    var text: String
}

enum ChatEvent: Equatable {
    case delta(String)
    /// truncated: 출력 한도에 걸려 답변이 잘렸는지
    case done(truncated: Bool)
    case failed(ChatError)
}

/// 화면에 보여 줄 오류 종류. 키나 서버 응답 원문은 담지 않는다.
enum ChatError: Equatable {
    case missingKey, noModel, unauthorized, forbidden, modelNotFound, noCredit, rateLimited, overloaded, tooLong, refused, badRequest
    case server(Int)
    case network
    case unexpectedEnd

    var message: String {
        switch self {
        case .missingKey: return T("설정에서 API 키를 저장해 주세요", "Save an API key in Settings")
        case .noModel: return T("설정에서 모델을 지정해 주세요", "Choose a model in Settings")
        case .unauthorized: return T("API 키가 올바르지 않습니다", "The API key isn't valid")
        case .forbidden: return T("이 키로는 사용할 수 없습니다", "This key doesn't have access")
        case .modelNotFound: return T("모델을 찾을 수 없습니다. 모델 ID를 확인해 주세요", "Model not found. Check the model ID")
        case .noCredit: return T("API 크레딧이 부족합니다", "Not enough API credit")
        case .rateLimited: return T("요청 한도를 넘었습니다. 잠시 뒤 다시 시도해 주세요", "Rate limit reached. Try again shortly")
        case .overloaded: return T("서비스가 혼잡합니다. 잠시 뒤 다시 시도해 주세요", "The service is busy. Try again shortly")
        case .tooLong: return T("요청이 너무 깁니다", "The request is too long")
        case .refused: return T("이 질문에는 답할 수 없습니다", "This question can't be answered")
        case .badRequest: return T("요청을 처리하지 못했습니다", "The request couldn't be processed")
        case .server(let code): return T("서버 오류가 발생했습니다 (\(code))", "Server error (\(code))")
        case .network: return T("네트워크에 연결할 수 없습니다", "Can't reach the network")
        case .unexpectedEnd: return T("응답이 중간에 끊겼습니다", "The response ended early")
        }
    }

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .server: return true
        default: return false
        }
    }

    /// HTTP 상태와 오류 본문의 앞부분으로 분류한다
    static func from(status: Int, body: String) -> ChatError {
        if body.contains("credit balance") || body.contains("insufficient_quota") { return .noCredit }
        switch status {
        case 400: return body.contains("API_KEY_INVALID") ? .unauthorized : .badRequest
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .modelNotFound
        case 413: return .tooLong
        case 429: return .rateLimited
        case 503, 529: return .overloaded
        default: return .server(status)
        }
    }
}

/// 서비스별 요청 만들기
enum ChatAPI {
    static let systemPrompt = """
        You are answering inside a small panel in a Mac's notch. Answer briefly and directly, in the language of the question. \
        Prefer short paragraphs over headings and tables.
        """
    static let maxOutputTokens = 4096

    /// 빠른 답변이 중요한 화면이므로 지원하는 모델은 effort를 낮춘다
    private static let lowEffortModels: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
    /// 안전 분류기가 거절하면 서버가 다른 모델로 다시 답하게 한다 (Haiku 5.5는 지원하지 않음)
    private static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    private static func baseURL(_ service: ChatService) -> String {
        #if DEV
        if let base = ProcessInfo.processInfo.environment["DMN_CHAT_BASE"] { return base }   // 개발용: 가짜 서버로 시험
        #endif
        switch service {
        case .claude: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        }
    }

    private static func encoded(_ model: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return model.addingPercentEncoding(withAllowedCharacters: allowed) ?? model
    }

    private static func authorize(_ request: inout URLRequest, _ service: ChatService, key: String) {
        switch service {
        case .claude:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        case .openai:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")   // 키가 URL에 남지 않게 헤더로 보낸다
        }
    }

    static func streamRequest(service: ChatService, model: String, key: String, turns: [ChatTurn]) -> URLRequest? {
        let path: String, body: [String: Any]
        var beta: String?
        switch service {
        case .claude:
            path = "/v1/messages"
            var b: [String: Any] = [
                "model": model, "max_tokens": maxOutputTokens, "stream": true, "system": systemPrompt,
                "messages": turns.map { ["role": $0.role.rawValue, "content": $0.text] },
            ]
            if lowEffortModels.contains(model) { b["output_config"] = ["effort": "low"] }
            if fallbackModels.contains(model) {
                b["fallbacks"] = "default"
                beta = "server-side-fallback-2026-07-01"
            }
            body = b
        case .openai:
            path = "/v1/responses"
            body = ["model": model, "stream": true, "store": false, "instructions": systemPrompt,
                    "max_output_tokens": maxOutputTokens,
                    "input": turns.map { ["role": $0.role.rawValue, "content": $0.text] }]
        case .gemini:
            path = "/v1beta/models/\(encoded(model)):streamGenerateContent?alt=sse"
            body = ["systemInstruction": ["parts": [["text": systemPrompt]]],
                    "generationConfig": ["maxOutputTokens": maxOutputTokens],
                    "contents": turns.map { ["role": $0.role == .user ? "user" : "model", "parts": [["text": $0.text]]] }]
        }
        guard let url = URL(string: baseURL(service) + path),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        authorize(&request, service, key: key)
        return request
    }

    /// 모델 정보 조회: 토큰을 쓰지 않고 키와 모델 ID를 함께 확인한다
    static func modelRequest(service: ChatService, model: String, key: String) -> URLRequest? {
        let version = service == .gemini ? "v1beta" : "v1"
        guard let url = URL(string: "\(baseURL(service))/\(version)/models/\(encoded(model))") else { return nil }
        var request = URLRequest(url: url)
        authorize(&request, service, key: key)
        return request
    }
}

/// 스트림의 `data:` 한 줄(JSON)을 이벤트로 바꾼다. 세 서비스 모두 한 이벤트가 한 줄에 들어온다.
struct ChatStreamParser {
    let service: ChatService
    private var stopReason: String?

    init(service: ChatService) { self.service = service }

    mutating func feed(_ line: String) -> [ChatEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return [] }
        switch service {
        case .claude: return feedClaude(json)
        case .openai: return feedOpenAI(json)
        case .gemini: return feedGemini(json)
        }
    }

    private mutating func feedClaude(_ json: [String: Any]) -> [ChatEvent] {
        switch json["type"] as? String {
        case "content_block_delta":
            // 생각 블록의 델타는 보여 주지 않는다
            guard let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return [] }
            return [.delta(text)]
        case "message_delta":
            stopReason = (json["delta"] as? [String: Any])?["stop_reason"] as? String
            return []
        case "message_stop":
            return [stopReason == "refusal" ? .failed(.refused) : .done(truncated: stopReason == "max_tokens")]
        case "error":
            switch (json["error"] as? [String: Any])?["type"] as? String {
            case "overloaded_error": return [.failed(.overloaded)]
            case "rate_limit_error": return [.failed(.rateLimited)]
            default: return [.failed(.server(500))]
            }
        default:
            return []
        }
    }

    private func feedOpenAI(_ json: [String: Any]) -> [ChatEvent] {
        switch json["type"] as? String {
        case "response.output_text.delta":
            return (json["delta"] as? String).map { [.delta($0)] } ?? []
        case "response.refusal.done": return [.failed(.refused)]
        case "response.completed": return [.done(truncated: false)]
        case "response.incomplete": return [.done(truncated: true)]
        case "response.failed", "error": return [.failed(.server(500))]
        default: return []
        }
    }

    private func feedGemini(_ json: [String: Any]) -> [ChatEvent] {
        if (json["promptFeedback"] as? [String: Any])?["blockReason"] != nil { return [.failed(.refused)] }
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { return [] }
        var events: [ChatEvent] = []
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        if !text.isEmpty { events.append(.delta(text)) }
        switch candidate["finishReason"] as? String {
        case nil, "FINISH_REASON_UNSPECIFIED": break
        case "STOP": events.append(.done(truncated: false))
        case "MAX_TOKENS": events.append(.done(truncated: true))
        default: events.append(.failed(.refused))   // SAFETY, RECITATION 등
        }
        return events
    }
}

/// 요청마다 쿠키·캐시 없는 임시 세션을 쓰고 끝나면 버린다 (대기 중에는 아무것도 돌지 않는다).
enum ChatClient {
    private static let retryDelays: [UInt64] = [1, 3]

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60    // 데이터가 이만큼 오지 않으면 실패
        config.timeoutIntervalForResource = 300
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    /// 답변을 스트리밍한다. onEvent는 백그라운드에서 불린다. 마지막 이벤트는 done 또는 failed이고,
    /// 돌려받은 Task를 취소하면 이벤트 없이 끝난다.
    @discardableResult
    static func stream(service: ChatService, model: String, key: String, turns: [ChatTurn],
                       onEvent: @escaping (ChatEvent) -> Void) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            guard let request = ChatAPI.streamRequest(service: service, model: model, key: key, turns: turns) else {
                onEvent(.failed(.badRequest))
                return
            }
            let session = makeSession()
            defer { session.invalidateAndCancel() }
            for attempt in 0...retryDelays.count {
                let error = await run(request, service: service, session: session, onEvent: onEvent)
                guard !Task.isCancelled else { return }
                guard let error else { return }
                // 글자가 나오기 전의 일시적 오류만 다시 시도한다
                guard error.failure.isRetryable, !error.gotOutput, attempt < retryDelays.count else {
                    onEvent(.failed(error.failure))
                    return
                }
                try? await Task.sleep(nanoseconds: retryDelays[attempt] * 1_000_000_000)
                guard !Task.isCancelled else { return }
            }
        }
    }

    /// 한 번 요청한다. 끝까지 정상이면 nil, 실패했으면 그 오류.
    private static func run(_ request: URLRequest, service: ChatService, session: URLSession,
                            onEvent: (ChatEvent) -> Void) async -> (failure: ChatError, gotOutput: Bool)? {
        var gotOutput = false
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return (ChatError.from(status: status, body: await head(of: bytes)), false)
            }
            var parser = ChatStreamParser(service: service)
            for try await line in bytes.lines {
                for event in parser.feed(line) {
                    switch event {
                    case .delta:
                        gotOutput = true
                        onEvent(event)
                    case .done:
                        onEvent(event)
                        return nil
                    case .failed(let failure):
                        return (failure, gotOutput)
                    }
                }
            }
            return (.unexpectedEnd, gotOutput)
        } catch {
            return (.network, gotOutput)
        }
    }

    /// 오류 본문의 앞부분 (분류에만 쓰고 화면에 보여 주지 않는다)
    private static func head(of bytes: URLSession.AsyncBytes) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 4096 { break }
            }
        } catch {}
        return String(decoding: data, as: UTF8.self)
    }

    /// 연결 테스트: 키와 모델 ID를 확인한다 (토큰을 쓰지 않음). 문제가 없으면 nil.
    static func test(service: ChatService, model: String, key: String) async -> ChatError? {
        guard let request = ChatAPI.modelRequest(service: service, model: model, key: key) else { return .badRequest }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200 ? nil : ChatError.from(status: status, body: String(decoding: data.prefix(4096), as: UTF8.self))
        } catch {
            return .network
        }
    }
}
