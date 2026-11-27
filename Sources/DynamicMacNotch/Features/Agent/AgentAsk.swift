import AppKit
import SwiftUI

/// 코딩 에이전트가 작업 중에 묻는 것(선택 질문·실행 허락)을 노치에서 답한다.
///
/// 흐름: 에이전트의 훅이 이 앱 실행 파일을 `--agent-ask=<에이전트>`로 실행 → 그 짧은 프로세스가 질문을 파일로 남기고
/// 분산 알림으로 본 앱에 알린 뒤 답을 기다린다 → 노치에서 고르면 본 앱이 답 파일을 쓰고 알린다 → 훅이 답을 에이전트에 돌려준다.
/// 질문 내용은 알림에 싣지 않고 이 사용자만 읽을 수 있는 폴더의 파일로 주고받는다.
///
/// - Claude Code: AskUserQuestion(PreToolUse 훅이 답을 넣음, 2026-11 실제 확인)과 실행 허락(PermissionRequest 훅).
/// - Codex: 실행 허락(PermissionRequest 훅)만. 선택 질문에 답하는 훅은 없다.
/// - Antigravity: 선택 질문(ask_question)을 알리기만 한다. 훅으로 답할 수 없어 누르면 Antigravity가 열린다.
///
/// 답하지 않으면 원래 화면(터미널 등)에서 묻는다: 알림을 그냥 누르거나, 그 앱으로 돌아가거나, 10분이 지나면.
enum AgentAsk {
    /// 시험용 통로 (`--agent-probe`가 실행 중인 노치 앱과 섞이지 않게)
    private static let channel = ProcessInfo.processInfo.environment["DMN_ASK_CHANNEL"].map { "." + $0 } ?? ""
    static let requestNote = Notification.Name("com.dynamicmacnotch.app.agent-ask" + channel)
    static let ackNote = Notification.Name("com.dynamicmacnotch.app.agent-ask-ack" + channel)
    static let replyNote = Notification.Name("com.dynamicmacnotch.app.agent-ask-reply" + channel)
    static let goneNote = Notification.Name("com.dynamicmacnotch.app.agent-ask-gone" + channel)

    /// 노치에서 답을 기다리는 시간. 지나면 원래 화면에서 묻는다.
    static let waitLimit: TimeInterval = 600
    /// 훅 설정에 적는 제한 시간(초): 기다리는 시간보다 조금 길게
    static let hookTimeout = 660
    /// 본 앱이 받았다고 답할 때까지 기다리는 시간 (앱이 꺼져 있으면 바로 원래 화면으로)
    static let ackLimit: TimeInterval = 1.0

    static func source(from arguments: [String]) -> AgentSource? {
        arguments.first { $0.hasPrefix("--agent-ask=") }.flatMap { AgentSource(rawValue: String($0.dropFirst("--agent-ask=".count))) }
    }

    // MARK: - 주고받는 내용

    struct Option: Codable, Equatable { var label: String; var detail: String }

    struct Question: Codable, Equatable {
        var question: String
        var header: String
        var options: [Option]
        var multiSelect: Bool
    }

    enum Kind: String, Codable { case question, permission, notice }

    struct Request: Codable, Identifiable, Equatable {
        var id: String
        var source: String
        var kind: Kind
        var project: String
        var hostBundle: String
        var hostPID: Int
        var hookPID: Int
        var questions: [Question]
        /// 실행 허락: 무엇을 하려는지 (도구 이름, 명령·파일)
        var tool: String = ""
        var detail: String = ""
        var created = Date()

        var agent: AgentSource { AgentSource(rawValue: source) ?? .claude }
        var target: String? { hostBundle.isEmpty ? nil : "\(hostBundle)|\(hostPID)" }
    }

    struct Reply: Codable, Equatable {
        enum Kind: String, Codable { case answer, allow, deny, release }
        var kind: Kind
        /// 질문 → 답 (여러 개를 고르면 ", "로 잇는다)
        var answers: [String: String] = [:]
        /// 거부할 때 에이전트에게 전할 말
        var message: String = ""
    }

    // MARK: - 훅 입력 → 질문

    /// Claude Code·Codex의 훅 입력(JSON)에서 질문을 만든다. 노치에서 다룰 것이 아니면 nil.
    static func request(from input: [String: Any], source: AgentSource) -> Request? {
        let event = input["hook_event_name"] as? String ?? ""
        let tool = input["tool_name"] as? String ?? ""
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        let cwd = input["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        var request = Request(id: UUID().uuidString, source: source.rawValue, kind: .question, project: URL(fileURLWithPath: cwd).lastPathComponent,
                              hostBundle: "", hostPID: 0, hookPID: Int(getpid()), questions: [])
        switch (source, event) {
        case (.claude, "PreToolUse") where tool == "AskUserQuestion":
            request.questions = questions(toolInput["questions"])
            guard !request.questions.isEmpty else { return nil }
        case (.claude, "PermissionRequest"), (.codex, "PermissionRequest"):
            // 질문·계획 승인은 따로 다룬다 (여기서 다시 묻지 않음)
            guard !["AskUserQuestion", "ExitPlanMode"].contains(tool) else { return nil }
            request.kind = .permission
            request.tool = tool
            request.detail = permissionDetail(toolInput)
        default:
            return nil
        }
        return request
    }

    /// Antigravity의 PreToolUse 입력(ask_question)에서 알림용 질문을 만든다
    static func antigravityNotice(from input: [String: Any]) -> Request? {
        guard let call = input["toolCall"] as? [String: Any], (call["name"] as? String) == "ask_question" else { return nil }
        var args = call["args"] as? [String: Any]
        if args == nil, let text = call["args"] as? String, let data = text.data(using: .utf8) {
            args = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let list = questions(args?["questions"])
        guard !list.isEmpty else { return nil }
        let folder = (input["workspacePaths"] as? [String])?.first ?? FileManager.default.currentDirectoryPath
        return Request(id: UUID().uuidString, source: AgentSource.antigravity.rawValue, kind: .notice,
                       project: URL(fileURLWithPath: folder).lastPathComponent, hostBundle: "", hostPID: 0, hookPID: 0, questions: list)
    }

    /// 질문 목록. Claude: question·header·options[label, description]·multiSelect, Antigravity: question·options(글자 또는 label)·is_multi_select
    static func questions(_ raw: Any?) -> [Question] {
        (raw as? [[String: Any]] ?? []).compactMap { q in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let options: [Option] = (q["options"] as? [Any] ?? []).compactMap { o in
                if let s = o as? String { return Option(label: s, detail: "") }
                guard let d = o as? [String: Any], let label = d["label"] as? String ?? d["text"] as? String else { return nil }
                return Option(label: label, detail: d["description"] as? String ?? "")
            }
            return Question(question: text, header: q["header"] as? String ?? "", options: options,
                            multiSelect: q["multiSelect"] as? Bool ?? q["is_multi_select"] as? Bool ?? false)
        }
    }

    /// 실행 허락에 보일 내용: 명령, 파일, 주소, 설명 순
    static func permissionDetail(_ input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        if let parts = input["command"] as? [String] { return parts.joined(separator: " ") }
        for key in ["file_path", "path", "url", "pattern", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    // MARK: - 답 → 훅 출력

    /// 에이전트에게 돌려줄 표준 출력. nil이면 아무것도 쓰지 않는다 (원래 화면에서 묻기).
    static func output(for reply: Reply, request: Request, input: [String: Any]) -> String? {
        let body: [String: Any]
        switch (request.kind, reply.kind) {
        case (.question, .answer):
            var updated = input["tool_input"] as? [String: Any] ?? [:]
            updated["answers"] = reply.answers
            body = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]]
        case (.permission, .allow):
            body = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
        case (.permission, .deny):
            var decision: [String: Any] = ["behavior": "deny"]
            if !reply.message.isEmpty { decision["message"] = reply.message }
            body = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        default:
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 파일 (이 사용자만 읽고 쓰는 폴더)

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Dynamic MacNotch/agent-ask" + channel, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    static func requestFile(_ id: String) -> URL { folder.appendingPathComponent("\(id).request.json") }
    static func replyFile(_ id: String) -> URL { folder.appendingPathComponent("\(id).reply.json") }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - 훅 쪽 (에이전트가 실행, 답을 받을 때까지 기다림)

    static func runHook(_ source: AgentSource, arguments: [String]) -> Never {
        let data = (try? FileHandle.standardInput.readToEnd()) ?? Data()
        let input = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let center = DistributedNotificationCenter.default()

        if source == .antigravity {
            // 에이전트의 동작은 바꾸지 않는다 (기본 규칙대로)
            FileHandle.standardOutput.write(Data("{\"decision\":\"allow\"}\n".utf8))
            if arguments.contains("--answered") {
                // 질문에 답했다 (PostToolUse): 노치의 알림을 지운다
                center.postNotificationName(goneNote, object: "antigravity", userInfo: nil, deliverImmediately: true)
            } else if var notice = antigravityNotice(from: input) {
                let host = guiHost()
                notice.hostBundle = host?.bundleIdentifier ?? ""
                notice.hostPID = Int(host?.processIdentifier ?? 0)
                write(notice, to: requestFile(notice.id))
                center.postNotificationName(requestNote, object: notice.id, userInfo: nil, deliverImmediately: true)
            }
            exit(0)
        }

        guard var request = request(from: input, source: source) else { exit(0) }
        let host = guiHost()
        request.hostBundle = host?.bundleIdentifier ?? ""
        request.hostPID = Int(host?.processIdentifier ?? 0)
        let id = request.id
        write(request, to: requestFile(id))
        func finish(_ text: String?) -> Never {
            try? FileManager.default.removeItem(at: requestFile(id))
            try? FileManager.default.removeItem(at: replyFile(id))
            if let text { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
            exit(0)
        }

        var acked = false
        let ackObserver = center.addObserver(forName: ackNote, object: id, queue: nil) { _ in acked = true }
        _ = ackObserver
        // 에이전트가 훅을 끝내면(사용자가 취소 등) 노치의 질문도 지운다
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                center.postNotificationName(goneNote, object: id, userInfo: nil, deliverImmediately: true)
                finish(nil)
            }
            src.resume()
            signalSources.append(src)
        }
        center.postNotificationName(requestNote, object: id, userInfo: nil, deliverImmediately: true)

        let start = Date()
        while true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if let reply = read(Reply.self, from: replyFile(id)) {
                finish(reply.kind == .release ? nil : output(for: reply, request: request, input: input))
            }
            let waited = Date().timeIntervalSince(start)
            // 본 앱이 꺼져 있으면 바로 원래 화면에서 묻는다
            if !acked, waited > ackLimit { finish(nil) }
            if waited > waitLimit {
                center.postNotificationName(goneNote, object: id, userInfo: nil, deliverImmediately: true)
                finish(nil)
            }
        }
    }

    private static var signalSources: [DispatchSourceSignal] = []

    /// 훅을 실행한 화면 앱 (터미널·VS Code·Claude 등)
    private static func guiHost() -> NSRunningApplication? {
        var pid = getppid()
        for _ in 0..<40 where pid > 1 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            pid = info.kp_eproc.e_ppid
        }
        return nil
    }
}

// MARK: - 본 앱 쪽

/// 기다리는 질문 목록. 맨 앞 질문을 노치에 상시 표시하고, 길게 누르면 고를 수 있는 팝업을 연다.
final class AgentAskStore: ObservableObject {
    static let shared = AgentAskStore()

    @Published private(set) var requests: [AgentAsk.Request] = []
    private weak var center: ActivityCenter?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    var current: AgentAsk.Request? { requests.first }

    func start(center: ActivityCenter) {
        self.center = center
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: AgentAsk.requestNote, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? String else { return }
            self?.received(id)
        })
        observers.append(dnc.addObserver(forName: AgentAsk.goneNote, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.object as? String else { return }
            // Antigravity가 질문에 답한 뒤에는 그 에이전트의 알림을 지운다
            if id == "antigravity" { self.remove { $0.kind == .notice } } else { self.remove { $0.id == id } }
        })
        // 질문한 앱으로 돌아가면 거기서 답하도록 넘긴다
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            for r in self.requests where Self.isHost(app, of: r) { self.release(r) }
        })
    }

    private func received(_ id: String) {
        guard let request = AgentAsk.read(AgentAsk.Request.self, from: AgentAsk.requestFile(id)) else { return }
        let settings = AppSettings.shared
        if request.kind == .notice {
            try? FileManager.default.removeItem(at: AgentAsk.requestFile(id))
            guard settings.agentAsk, !isViewing(request) else { return }
            remove { $0.kind == .notice && $0.source == request.source }
            append(request)
            return
        }
        DistributedNotificationCenter.default().postNotificationName(AgentAsk.ackNote, object: id, userInfo: nil, deliverImmediately: true)
        // 꺼져 있거나 그 앱을 보고 있으면 원래 화면에서 묻는다
        guard settings.agentAsk, !isViewing(request) else { return reply(request, .init(kind: .release)) }
        append(request)
    }

    private func append(_ request: AgentAsk.Request) {
        requests.append(request)
        publish()
        if timer == nil {
            // 훅이 끝났으면(에이전트에서 취소 등) 지운다. 알리기만 하는 질문은 10분 뒤에 지운다.
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.remove { r in r.kind == .notice || r.hookPID < 0 ? Date().timeIntervalSince(r.created) > AgentAsk.waitLimit : kill(pid_t(r.hookPID), 0) != 0 }
            }
        }
    }

    // MARK: 답하기

    func answer(_ request: AgentAsk.Request, answers: [String: String]) { reply(request, .init(kind: .answer, answers: answers)) }
    func allow(_ request: AgentAsk.Request) { reply(request, .init(kind: .allow)) }
    func deny(_ request: AgentAsk.Request, message: String) { reply(request, .init(kind: .deny, message: message)) }

    /// 원래 화면(터미널 등)에서 묻게 한다
    func release(_ request: AgentAsk.Request) {
        if request.kind == .notice { remove { $0.id == request.id } } else { reply(request, .init(kind: .release)) }
    }

    /// 알림을 그냥 눌렀을 때: 질문한 앱을 열고 거기서 답하게 한다
    func openHost() {
        guard let request = current else { return }
        release(request)
        AgentNotify.open(request.target ?? request.agent.appBundleID)
    }

    private func reply(_ request: AgentAsk.Request, _ reply: AgentAsk.Reply) {
        // 미리보기 질문은 기다리는 훅이 없다
        guard request.hookPID >= 0 else { return remove { $0.id == request.id } }
        AgentAsk.write(reply, to: AgentAsk.replyFile(request.id))
        DistributedNotificationCenter.default().postNotificationName(AgentAsk.replyNote, object: request.id, userInfo: nil, deliverImmediately: true)
        remove { $0.id == request.id }
    }

    private func remove(where match: (AgentAsk.Request) -> Bool) {
        let before = requests.count
        requests.removeAll(where: match)
        guard requests.count != before else { return }
        publish()
        if requests.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: 노치 표시

    private func publish() {
        guard let center else { return }
        guard let r = current else { return center.removePersistent(.agentAsk) }
        let more = requests.count > 1 ? " +\(requests.count - 1)" : ""
        let label = r.kind == .permission ? T("허락", "Allow?") : T("질문", "Question")
        center.setPersistent(NotchActivity(
            kind: .agentAsk, priority: ActivityPriority.agentAsk, symbol: r.agent.symbol, tint: r.agent.tint,
            value: .text(label + more), title: r.project.isEmpty ? r.agent.name : "\(r.agent.name) · \(r.project)",
            subtitle: Self.summary(r), targetApp: r.target))
    }

    static func summary(_ r: AgentAsk.Request) -> String {
        switch r.kind {
        case .permission: return AgentNotify.oneLine("\(r.tool) \(r.detail)", limit: 80)
        default: return AgentNotify.oneLine(r.questions.first?.question ?? "", limit: 80)
        }
    }

    // MARK: 보고 있는 앱

    private func isViewing(_ r: AgentAsk.Request) -> Bool {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true { return false }
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return Self.isHost(front, of: r)
    }

    private static func isHost(_ app: NSRunningApplication, of r: AgentAsk.Request) -> Bool {
        if r.hostPID > 0 { return app.processIdentifier == pid_t(r.hostPID) }
        return app.bundleIdentifier == (r.hostBundle.isEmpty ? r.agent.appBundleID : r.hostBundle)
    }

    /// 미리보기: 실제 에이전트 없이 질문 하나를 띄운다 (답은 아무 데도 보내지 않음)
    func preview(_ request: AgentAsk.Request) {
        requests.removeAll { $0.hookPID == -1 }
        var r = request
        r.hookPID = -1
        requests.insert(r, at: 0)
        publish()
    }
}
