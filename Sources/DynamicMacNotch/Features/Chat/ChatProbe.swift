#if DEV
import Foundation

/// 개발용: 화면 없이 채팅 호출부를 시험한다 (개발 빌드에만 포함).
/// `--chat-probe=<명령>:<서비스>[:<모델>]` 명령: setkey(표준 입력) haskey delkey test ask(표준 입력)
/// 키는 DMN_CHAT_KEY가 있으면 그 값, 없으면 키체인에서 읽는다. 키 값은 출력하지 않는다.
enum ChatProbe {
    static func runIfRequested() {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--chat-probe=") }) else { return }
        let parts = arg.dropFirst("--chat-probe=".count).split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let service = ChatService(rawValue: parts[1]) else { exit(2) }
        let model = parts.count > 2 ? parts[2] : service.defaultModel
        let input = { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        let key = { ProcessInfo.processInfo.environment["DMN_CHAT_KEY"] ?? ChatKeychain.read(for: service) ?? "" }
        let done = DispatchSemaphore(value: 0)
        switch parts[0] {
        case "setkey": print("saved=\(ChatKeychain.save(input(), for: service))")
        case "haskey": print("has=\(ChatKeychain.has(for: service))")
        case "readkey": print("readable=\(ChatKeychain.read(for: service) != nil)")
        case "delkey":
            ChatKeychain.delete(for: service)
            print("has=\(ChatKeychain.has(for: service))")
        case "test":
            let k = key()
            Task.detached {
                let error = await ChatClient.test(service: service, model: model, key: k)
                print(error.map { "failed: \($0) | \($0.message)" } ?? "passed")
                done.signal()
            }
            done.wait()
        case "ask":
            let start = Date()
            let question = input()
            ChatClient.stream(service: service, model: model, key: key(), turns: [ChatTurn(role: .user, text: question)]) { event in
                print(String(format: "%6.2f", Date().timeIntervalSince(start)), event)
                switch event {
                case .delta: break
                default: done.signal()
                }
            }
            done.wait()
        default: exit(2)
        }
        exit(0)
    }
}
#endif
