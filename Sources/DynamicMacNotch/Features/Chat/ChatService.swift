import Foundation
import Security

/// AI 채팅에 쓸 서비스. 모두 사용자가 직접 넣은 API 키로 동작한다 (사용량은 각 회사가 키 주인에게 청구).
enum ChatService: String, CaseIterable, Identifiable {
    case claude, openai, gemini

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "GPT"
        case .gemini: return "Gemini"
        }
    }

    var company: String {
        switch self {
        case .claude: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini: return "Google"
        }
    }

    /// 모델을 고르지 않았을 때 쓸 값. GPT·Gemini는 모델이 자주 바뀌므로 코드에 박지 않고 사용자가 입력한다.
    var defaultModel: String { self == .claude ? "claude-haiku-5-5" : "" }

    var keysURL: URL {
        switch self {
        case .claude: return URL(string: "https://platform.claude.com/settings/keys")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        }
    }
}

/// API 키는 키체인에만 저장한다 (설정 파일·로그에는 남기지 않는다).
enum ChatKeychain {
    private static let serviceName = "com.dynamicmacnotch.app.chat"

    private static func query(_ service: ChatService) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: serviceName,
         kSecAttrAccount as String: service.rawValue]
    }

    @discardableResult
    static func save(_ key: String, for service: ChatService) -> Bool {
        delete(for: service)
        var item = query(service)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "Dynamic MacNotch \(service.company) API key"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func read(for service: ChatService) -> String? {
        #if DEV
        if let key = ProcessInfo.processInfo.environment["DMN_CHAT_KEY"] { return key }   // 개발용: 키체인 없이 가짜 서버로 시험
        #endif
        var q = query(service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 저장 여부만 확인한다 (키 값을 메모리로 읽지 않는다)
    static func has(for service: ChatService) -> Bool {
        #if DEV
        if ProcessInfo.processInfo.environment["DMN_CHAT_KEY"] != nil { return true }
        #endif
        var q = query(service)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(for service: ChatService) {
        SecItemDelete(query(service) as CFDictionary)
    }
}
