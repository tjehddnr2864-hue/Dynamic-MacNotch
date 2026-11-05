import Foundation

/// 모델 메뉴의 묶음. 서비스가 등급을 알려 주지 않으므로 설명·이름으로 판단한다 (모르면 등급 없음).
enum ChatModelTier: Int, CaseIterable, Identifiable {
    case fast, balanced, capable

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fast: return T("빠름", "Fast")
        case .balanced: return T("균형", "Balanced")
        case .capable: return T("고성능", "Most Capable")
        }
    }

    /// 설명이 있으면 먼저 본다 (예: Codex 카탈로그의 "Fast and affordable model")
    static func of(_ id: String, description: String? = nil) -> ChatModelTier? {
        if let description = description?.lowercased() {
            if description.contains("balanced") { return .balanced }
            if description.contains("most capable") || description.contains("flagship") || description.contains("frontier") { return .capable }
            if description.contains("fast") || description.contains("efficient") || description.contains("affordable") { return .fast }
        }
        // 낱말 단위로 본다 ("gemini" 안의 "mini"처럼 일부만 겹치는 경우를 피한다)
        let words = Set(id.lowercased().split(separator: "-").map(String.init))
        func has(_ names: String...) -> Bool { names.contains(where: words.contains) }
        // 작은 쪽을 먼저 본다 (flash-lite는 flash보다 빠른 등급)
        if has("luna", "mini", "nano", "lite", "haiku", "spark") { return .fast }
        if has("astra", "opus", "fable", "pro", "max", "ultra") { return .capable }
        if has("sol", "terra", "flash", "sonnet") { return .balanced }
        return nil
    }
}

struct ChatModelOption: Identifiable, Equatable {
    let id: String
    let tier: ChatModelTier?
}

enum ChatModels {
    /// 목록을 받아 오지 않는 서비스의 메뉴
    static func presets(_ service: ChatService) -> [ChatModelOption] {
        guard service == .claude else { return [] }
        return ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"].map { ChatModelOption(id: $0, tier: ChatModelTier.of($0)) }
    }

    /// 서비스에서 목록을 받아 오는지 (아니면 정해 둔 목록을 쓴다)
    static func canFetch(_ service: ChatService) -> Bool {
        service == .openai || service == .gemini
    }

    static func fetch(service: ChatService, key: String) async -> Result<[ChatModelOption], ChatError> {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var found: [ChatModelOption] = []
        var pageToken: String?
        // Gemini는 여러 쪽으로 나눠 준다
        for _ in 0..<5 {
            guard let request = ChatAPI.modelListRequest(service: service, key: key, pageToken: pageToken) else { return .failure(.badRequest) }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    return .failure(ChatError.from(status: status, body: String(decoding: data.prefix(4096), as: UTF8.self)))
                }
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.badRequest) }
                found += service == .gemini ? geminiModels(json) : openAIModels(json)
                pageToken = json["nextPageToken"] as? String
                if pageToken?.isEmpty != false { break }
            } catch {
                return .failure(.network)
            }
        }
        return .success(arranged(found))
    }

    /// 대화용이 아닌 모델은 뺀다 (이미지·음성·임베딩 등)
    private static let excluded = ["embedding", "whisper", "tts", "dall-e", "image", "audio", "realtime", "transcribe", "moderation",
                                   "instruct", "sora", "imagen", "veo", "aqa", "live", "robotics", "search-preview", "cyber"]

    private static func openAIModels(_ json: [String: Any]) -> [ChatModelOption] {
        ((json["data"] as? [[String: Any]]) ?? []).compactMap { model in
            guard let id = model["id"] as? String else { return nil }
            let name = id.lowercased()
            let isChat = name.hasPrefix("gpt-") || name.hasPrefix("chatgpt-") || name.hasPrefix("codex-")
                || (name.first == "o" && name.dropFirst().first?.isNumber == true)
            guard isChat, !excluded.contains(where: name.contains) else { return nil }
            return ChatModelOption(id: id, tier: ChatModelTier.of(id))
        }
    }

    private static func geminiModels(_ json: [String: Any]) -> [ChatModelOption] {
        ((json["models"] as? [[String: Any]]) ?? []).compactMap { model in
            guard let name = model["name"] as? String,
                  (model["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
            guard !excluded.contains(where: id.lowercased().contains) else { return nil }
            return ChatModelOption(id: id, tier: ChatModelTier.of(id))
        }
    }

    /// 날짜가 붙은 고정 버전은 같은 이름의 최신 별칭이 있으면 숨기고, 이름순(최신이 위로) 정렬한다
    static func arranged(_ models: [ChatModelOption]) -> [ChatModelOption] {
        let ids = Set(models.map(\.id))
        let visible = models.filter { option in
            guard let range = option.id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) else { return true }
            return !ids.contains(String(option.id[..<range.lowerBound]))
        }
        return visible.sorted { $0.id.compare($1.id, options: .numeric) == .orderedDescending }
    }
}
