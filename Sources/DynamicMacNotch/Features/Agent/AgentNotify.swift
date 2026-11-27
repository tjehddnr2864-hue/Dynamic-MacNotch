import AppKit
import SwiftUI

/// 코딩 에이전트 (Claude Code · Codex · Antigravity)
enum AgentSource: String, CaseIterable, Identifiable {
    case claude, codex, antigravity

    var id: String { rawValue }
    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }
    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "arrowshape.up"
        }
    }
    /// 에이전트 자체 앱
    var appBundleID: String {
        switch self {
        case .claude: return "com.anthropic.claudefordesktop"
        case .codex: return "com.openai.codex"
        case .antigravity: return "com.google.antigravity"
        }
    }
    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.55, green: 0.62, blue: 1.0)
        case .antigravity: return Color(red: 0.36, green: 0.55, blue: 0.98)
        }
    }
}

/// 작업 완료 알림.
/// Claude Code·Antigravity(Stop 훅)·Codex(notify)가 작업을 끝내면 이 앱 실행 파일을 `--agent-done=<에이전트>`로 잠깐 실행하고,
/// 그 짧은 프로세스가 분산 알림으로 본 앱에 알린 뒤 바로 끝난다. 알림을 누르면 에이전트가 돌던 앱(터미널·Claude·Codex 등)을 연다.
enum AgentNotify {
    static let notification = Notification.Name("com.dynamicmacnotch.app.agent")

    static func source(from arguments: [String]) -> AgentSource? {
        arguments.first { $0.hasPrefix("--agent-done=") }.flatMap { AgentSource(rawValue: String($0.dropFirst("--agent-done=".count))) }
    }

    // MARK: 훅 쪽 (짧게 실행되고 끝남)

    static func runHook(_ source: AgentSource, arguments: [String]) -> Never {
        var payloadArgs = arguments
        // Codex notify를 이어받은 경우: 원래 notify 명령도 그대로 실행한다 (--chain 원래명령... --end-chain [Codex가 붙인 인자])
        if let i = arguments.firstIndex(of: "--chain"), let j = arguments.firstIndex(of: "--end-chain"), i < j {
            let previous = Array(arguments[(i + 1)..<j])
            payloadArgs = Array(arguments[(j + 1)...])
            if let exe = previous.first {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = Array(previous.dropFirst()) + payloadArgs
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
            }
        }
        // 프로젝트 폴더와 끝난 작업(사용자가 마지막으로 보낸 요청)
        var folder = FileManager.default.currentDirectoryPath
        var task = "", failed = false
        switch source {
        case .codex:
            // Codex는 마지막 인자로 JSON을 넘긴다: {"cwd": ..., "input-messages": [...], "last-assistant-message": ...}
            if let last = payloadArgs.last, let data = last.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let cwd = obj["cwd"] as? String { folder = cwd }
                task = (obj["input-messages"] as? [String])?.last ?? ""
            }
        case .claude:
            // Claude Code는 표준 입력으로 JSON을 준다: {"cwd": ..., "transcript_path": ...}
            if let data = try? FileHandle.standardInput.readToEnd(),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let cwd = obj["cwd"] as? String { folder = cwd }
                if let path = obj["transcript_path"] as? String { task = lastUserPrompt(transcript: path) }
            }
        case .antigravity:
            // 에이전트의 동작을 바꾸지 않는다: "continue"가 아닌 결정은 그대로 멈추게 한다
            FileHandle.standardOutput.write(Data("{\"decision\":\"stop\"}\n".utf8))
            guard let data = try? FileHandle.standardInput.readToEnd(), let event = antigravityStop(data) else { exit(0) }
            if let path = event.folder { folder = path }
            task = event.task
            failed = event.failed
        }
        let app = guiHost()
        // 요청 글은 다른 프로세스가 볼 수 있는 알림에 싣지 않는다 (AgentChannel)
        AgentChannel.post(notification, object: source.rawValue, payload: [
            "project": URL(fileURLWithPath: folder).lastPathComponent,
            "task": AgentChannel.redact(oneLine(task, limit: 80)),
            "failed": failed,
            "bundle": app?.bundleIdentifier ?? "",
            "pid": Int(app?.processIdentifier ?? 0)])
        exit(0)
    }

    /// Antigravity의 Stop 훅 입력. 백그라운드 작업이 남아 있으면(fullyIdle == false) 아직 끝난 것이 아니므로 nil.
    static func antigravityStop(_ data: Data) -> (folder: String?, task: String, failed: Bool)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["fullyIdle"] as? Bool != false else { return nil }
        // 실제 값은 NO_TOOL_CALL처럼 대문자이고 문서는 소문자다 (agy 1.5.17). 정상이면 error는 빈 글자.
        let failed = (obj["terminationReason"] as? String ?? "").lowercased().contains("error") || !(obj["error"] as? String ?? "").isEmpty
        return ((obj["workspacePaths"] as? [String])?.first ?? obj["cwd"] as? String, obj["lastUserInput"] as? String ?? "", failed)
    }

    /// 대화 기록(JSONL)에서 사용자가 마지막으로 보낸 요청. 파일 끝 512KB만 읽는다.
    /// 도구 결과·시스템이 붙인 메시지·요약·하위 작업·태그로 시작하는 메시지는 건너뛴다.
    static func lastUserPrompt(transcript path: String) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return "" }
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "user",
                  obj["isMeta"] as? Bool != true, obj["isSidechain"] as? Bool != true,
                  obj["isCompactSummary"] as? Bool != true, obj["toolUseResult"] == nil,
                  let message = obj["message"] as? [String: Any] else { continue }
            var parts: [String] = []
            if let s = message["content"] as? String { parts = [s] }
            else if let list = message["content"] as? [[String: Any]] {
                parts = list.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            }
            let prompt = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.hasPrefix("<") } ?? ""
            if !prompt.isEmpty { return prompt }
        }
        return ""
    }

    /// 한 줄로 줄이고 길면 자른다
    static func oneLine(_ s: String, limit: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// 이 프로세스를 띄운 화면 앱 (부모 프로세스를 거슬러 올라가 처음 만나는 일반 앱: 터미널·VS Code·Claude 등)
    static func guiHost() -> NSRunningApplication? {
        var pid = getppid()
        for _ in 0..<40 where pid > 1 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
            pid = parent(of: pid)
        }
        return nil
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    // MARK: 본 앱 쪽

    /// 알림을 받아 노치에 띄운다. 누르면 열 앱은 activity.targetApp("번들ID|pid")에 담는다.
    static func observe(center: ActivityCenter) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            // 파일은 알림을 쓰지 않더라도 먼저 읽어 지운다
            guard let info = AgentChannel.take(note), AppSettings.shared.agentAlerts,
                  let raw = note.object as? String, let source = AgentSource(rawValue: raw) else { return }
            let project = info["project"] as? String ?? ""
            let bundle = info["bundle"] as? String ?? ""
            let pid = info["pid"] as? Int ?? 0
            let task = info["task"] as? String ?? ""
            let failed = info["failed"] as? Bool ?? false
            // 그 에이전트가 돌던 앱을 지금 보고 있으면 알리지 않는다 (화면이 잠겨 있으면 보고 있는 것이 아님)
            if isViewing(source, bundle: bundle, pid: pid) { return }
            // 작업 팝업을 보던 중이라 이미 상세 완료 알림을 띄웠으면 다시 띄우지 않는다
            guard AgentLiveStore.shared.shouldPostDone(source, project: project) else { return }
            center.post(activity(source, project: project, task: task, target: bundle.isEmpty ? nil : "\(bundle)|\(pid)", failed: failed))
        }
    }

    /// 맨 앞 앱이 에이전트가 돌던 앱인지. 돌던 앱을 알 수 없으면 에이전트 자체 앱(Claude·Codex)으로 판단한다.
    private static func isViewing(_ source: AgentSource, bundle: String, pid: Int) -> Bool {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true { return false }
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if pid > 0, front.processIdentifier == pid_t(pid) { return true }
        guard let id = front.bundleIdentifier else { return false }
        return bundle.isEmpty ? id == source.appBundleID : id == bundle
    }

    /// 컴팩트: 왼쪽 에이전트 아이콘, 오른쪽 '완료'.
    /// 상세(설정): 제목 'Claude Code · 프로젝트', 아래에 끝난 작업(마지막으로 보낸 요청)을 한 줄로.
    static func activity(_ source: AgentSource, project: String, task: String, target: String?,
                         style: AlertStyle? = nil, failed: Bool = false) -> NotchActivity {
        let detailed = (style ?? AppSettings.shared.agentStyle) == .detail
        let done = failed ? T("중단됨", "Stopped") : T("완료", "Done")
        let title = project.isEmpty ? (failed ? T("\(source.name) 작업 중단", "\(source.name) Stopped") : T("\(source.name) 작업 완료", "\(source.name) Finished"))
                                    : "\(source.name) · \(project)"
        let subtitle = task.isEmpty ? (failed ? T("오류로 중단됨 · 눌러서 열기", "Stopped by an error · Click to open") : T("작업 완료 · 눌러서 열기", "Finished · Click to open")) : task
        return NotchActivity(kind: .agent, priority: ActivityPriority.info, presentation: detailed ? .detail : .compact,
                             duration: detailed ? 7 : 5, symbol: source.symbol, tint: source.tint,
                             value: .text(done), title: title, subtitle: subtitle, targetApp: target)
    }

    /// 알림을 눌렀을 때: 에이전트가 돌던 앱을 앞으로 (같은 창이 남아 있으면 그 앱 그대로)
    static func open(_ target: String?) {
        guard let target else { return }
        let parts = target.split(separator: "|").map(String.init)
        let running = parts.count > 1 ? NSRunningApplication(processIdentifier: pid_t(Int(parts[1]) ?? 0)) : nil
        let url = running?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.first ?? "")
        guard let url else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

// MARK: - 훅 설치 (설정 창에서 '연결'을 눌렀을 때만)

/// Claude Code: ~/.claude/settings.json 의 hooks.Stop 에 명령 하나를 더한다.
/// Antigravity: ~/.gemini/config/hooks.json 에 이 앱 이름의 훅 하나(Stop)를 더한다. 그 폴더의 다른 파일은 읽지 않는다.
/// Codex: ~/.codex/config.toml 의 notify 를 이 앱으로 바꾸되, 원래 notify 명령은 이어서 그대로 실행한다.
/// 처음 바꾸기 전에 원본을 *.dynamicmacnotch.bak 으로 남긴다.
enum AgentHooks {
    enum HookError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case .unreadable(let why): return why }
        }
    }

    #if DEV
    /// 시험용 홈 폴더 (`--agent-probe`)
    static var testHome: URL?
    private static var home: URL { testHome ?? FileManager.default.homeDirectoryForCurrentUser }
    #else
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    #endif
    static var claudeFile: URL { home.appendingPathComponent(".claude/settings.json") }
    static var codexFile: URL { home.appendingPathComponent(".codex/config.toml") }
    static var antigravityFile: URL { home.appendingPathComponent(".gemini/config/hooks.json") }
    /// Codex의 훅 파일 (질문·실행 허락용. 작업 완료는 config.toml의 notify)
    static var codexHooksFile: URL { home.appendingPathComponent(".codex/hooks.json") }

    static func file(_ s: AgentSource) -> URL {
        switch s {
        case .claude: return claudeFile
        case .codex: return codexFile
        case .antigravity: return antigravityFile
        }
    }
    private static var exe: String { Bundle.main.executablePath ?? "/Applications/Dynamic MacNotch.app/Contents/MacOS/DynamicMacNotch" }

    static func isInstalled(_ s: AgentSource) -> Bool {
        (try? String(contentsOf: file(s), encoding: .utf8))?.contains("--agent-done=\(s.rawValue)") ?? false
    }

    /// 질문·실행 허락 훅이 들어 있는지
    static func isAskInstalled(_ s: AgentSource) -> Bool {
        (try? String(contentsOf: s == .codex ? codexHooksFile : file(s), encoding: .utf8))?.contains("--agent-ask=\(s.rawValue)") ?? false
    }

    /// 실시간 작업 훅이 들어 있는지
    static func isLiveInstalled(_ s: AgentSource) -> Bool {
        (try? String(contentsOf: s == .codex ? codexHooksFile : file(s), encoding: .utf8))?.contains("--agent-live=\(s.rawValue)") ?? false
    }

    /// 예전에 연결한 경우(작업 완료만, 또는 질문까지): 다시 연결하면 빠진 훅만 더한다
    static func needsUpdate(_ s: AgentSource) -> Bool { isInstalled(s) && (!isAskInstalled(s) || !isLiveInstalled(s)) }

    static func install(_ s: AgentSource) throws {
        switch s {
        case .claude: try installClaude()
        case .codex: try installCodex(); try installCodexAsk()
        case .antigravity: try installAntigravity()
        }
    }

    static func uninstall(_ s: AgentSource) throws {
        switch s {
        case .claude: try uninstallClaude()
        case .codex: try uninstallCodex(); try uninstallCodexAsk()
        case .antigravity: try uninstallAntigravity()
        }
    }

    // Claude Code·Codex 훅 형식: {"hooks": {"이벤트": [{"matcher": …, "hooks": [{"type": "command", "command": …}]}]}}

    private static func addHook(_ obj: inout [String: Any], event: String, matcher: String?, command: String, timeout: Int?, async: Bool = false) {
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        var groups = hooks[event] as? [[String: Any]] ?? []
        // 같은 표시(--agent-…=…)가 이미 있으면 (실행 파일 위치가 달라도) 더하지 않는다
        let marker = command.components(separatedBy: " ").first { $0.hasPrefix("--agent-") } ?? command
        guard !groups.contains(where: { (($0["hooks"] as? [[String: Any]]) ?? []).contains { (($0["command"] as? String) ?? "").contains(marker) } }) else { return }
        var handler: [String: Any] = ["type": "command", "command": command]
        if let timeout { handler["timeout"] = timeout }
        if async { handler["async"] = true }
        var group: [String: Any] = ["hooks": [handler]]
        if let matcher { group["matcher"] = matcher }
        groups.append(group)
        hooks[event] = groups
        obj["hooks"] = hooks
    }

    /// 이 앱의 명령(표시 글자가 들어간 것)만 지운다. 비면 그 이벤트·hooks 키도 지운다.
    private static func removeHooks(_ obj: inout [String: Any], marker: String) {
        guard var hooks = obj["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                var g = group
                let list = (g["hooks"] as? [[String: Any]] ?? []).filter { !(($0["command"] as? String) ?? "").contains(marker) }
                if list.isEmpty { return nil }
                g["hooks"] = list
                return g
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        obj["hooks"] = hooks.isEmpty ? nil : hooks
    }

    private static func backup(_ file: URL) {
        let bak = file.appendingPathExtension("dynamicmacnotch.bak")
        if FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: bak.path) {
            try? FileManager.default.copyItem(at: file, to: bak)
        }
    }

    // Claude Code

    private static func readClaude() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: claudeFile) else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.unreadable(T("~/.claude/settings.json을 읽을 수 없습니다 (JSON 형식 확인)", "Can't read ~/.claude/settings.json (check the JSON)"))
        }
        return obj
    }

    private static func writeClaude(_ obj: [String: Any]) throws {
        backup(claudeFile)
        try FileManager.default.createDirectory(at: claudeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: claudeFile, options: .atomic)
    }

    /// 작업 완료(Stop), 선택 질문(PreToolUse · AskUserQuestion), 실행 허락(PermissionRequest)
    private static func installClaude() throws {
        guard !isInstalled(.claude) || !isAskInstalled(.claude) || !isLiveInstalled(.claude) else { return }
        var obj = try readClaude()
        addHook(&obj, event: "Stop", matcher: nil, command: "\"\(exe)\" --agent-done=claude", timeout: nil)
        let ask = "\"\(exe)\" --agent-ask=claude"
        addHook(&obj, event: "PreToolUse", matcher: "AskUserQuestion", command: ask, timeout: AgentAsk.hookTimeout)
        addHook(&obj, event: "PermissionRequest", matcher: nil, command: ask, timeout: AgentAsk.hookTimeout)
        // 실시간 작업: Claude Code를 기다리게 하지 않도록 따로 돌린다(async)
        let live = "\"\(exe)\" --agent-live=claude"
        for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"] {
            addHook(&obj, event: event, matcher: nil, command: live, timeout: 10, async: true)
        }
        try writeClaude(obj)
    }

    private static func uninstallClaude() throws {
        var obj = try readClaude()
        guard obj["hooks"] != nil else { return }
        removeHooks(&obj, marker: "--agent-done=claude")
        removeHooks(&obj, marker: "--agent-ask=claude")
        removeHooks(&obj, marker: "--agent-live=claude")
        try writeClaude(obj)
    }

    // Codex 질문 훅: ~/.codex/hooks.json 의 PermissionRequest (Codex에서 /hooks로 한 번 신뢰해야 실행된다)

    private static func readCodexHooks() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: codexHooksFile), !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.unreadable(T("~/.codex/hooks.json을 읽을 수 없습니다 (JSON 형식 확인)", "Can't read ~/.codex/hooks.json (check the JSON)"))
        }
        return obj
    }

    private static func writeCodexHooks(_ obj: [String: Any]) throws {
        backup(codexHooksFile)
        try FileManager.default.createDirectory(at: codexHooksFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: codexHooksFile.resolvingSymlinksInPath(), options: .atomic)
    }

    private static func installCodexAsk() throws {
        guard !isAskInstalled(.codex) || !isLiveInstalled(.codex) else { return }
        var obj = try readCodexHooks()
        addHook(&obj, event: "PermissionRequest", matcher: nil, command: "\"\(exe)\" --agent-ask=codex", timeout: AgentAsk.hookTimeout)
        for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"] {
            addHook(&obj, event: event, matcher: nil, command: "\"\(exe)\" --agent-live=codex", timeout: 5)
        }
        try writeCodexHooks(obj)
    }

    private static func uninstallCodexAsk() throws {
        guard FileManager.default.fileExists(atPath: codexHooksFile.path) else { return }
        var obj = try readCodexHooks()
        removeHooks(&obj, marker: "--agent-ask=codex")
        removeHooks(&obj, marker: "--agent-live=codex")
        try writeCodexHooks(obj)
    }

    // Antigravity: {"훅 이름": {"Stop": [{"type": "command", "command": "…"}]}} (antigravity.google/docs/hooks)

    private static let antigravityHook = "dynamic-macnotch"

    /// 파일이 없거나 비어 있으면 빈 목록. 읽을 수 없는 내용이면 덮어쓰지 않고 알린다.
    private static func readAntigravity() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: antigravityFile.path) else { return [:] }
        let data = try Data(contentsOf: antigravityFile)
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.unreadable(T("~/.gemini/config/hooks.json을 읽을 수 없습니다 (JSON 형식 확인)", "Can't read ~/.gemini/config/hooks.json (check the JSON)"))
        }
        return obj
    }

    private static func writeAntigravity(_ obj: [String: Any]) throws {
        backup(antigravityFile)
        try FileManager.default.createDirectory(at: antigravityFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: antigravityFile.resolvingSymlinksInPath(), options: .atomic)
    }

    /// 이 앱 이름의 훅 하나: 작업 완료(Stop)와 선택 질문 알림(ask_question 앞·뒤)
    private static func installAntigravity() throws {
        guard !isInstalled(.antigravity) || !isAskInstalled(.antigravity) || !isLiveInstalled(.antigravity) else { return }
        var obj = try readAntigravity()
        let ask = "\"\(exe)\" --agent-ask=antigravity", live = "\"\(exe)\" --agent-live=antigravity"
        func handler(_ command: String) -> [String: Any] { ["type": "command", "command": command, "timeout": 10] }
        // 형식은 2026-11 agy 1.5.17의 작업 폴더 훅으로 확인 (PreInvocation·PreToolUse·PostToolUse·Stop)
        obj[antigravityHook] = [
            "Stop": [handler("\"\(exe)\" --agent-done=antigravity"), handler(live)],
            "PreInvocation": [handler(live)],
            "PreToolUse": [["matcher": "ask_question", "hooks": [handler(ask)]] as [String: Any], ["matcher": ".*", "hooks": [handler(live)]] as [String: Any]],
            "PostToolUse": [["matcher": "ask_question", "hooks": [handler(ask + " --answered")]] as [String: Any], ["matcher": ".*", "hooks": [handler(live)]] as [String: Any]],
        ]
        try writeAntigravity(obj)
    }

    private static func uninstallAntigravity() throws {
        var obj = try readAntigravity()
        guard obj.removeValue(forKey: antigravityHook) != nil else { return }
        try writeAntigravity(obj)
    }

    // Codex

    /// 맨 위(첫 [표] 앞) 영역의 notify 줄 위치
    private static func notifyLine(_ lines: [String]) -> Int? {
        let top = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        return lines[..<top].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("notify") && $0.contains("=") }
    }

    /// notify = ["a", "b"] 의 문자열들
    private static func tomlStrings(_ line: String) -> [String]? {
        guard let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]"), open < close else { return nil }
        let body = String(line[line.index(after: open)..<close])
        let re = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        return re.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
            Range($0.range(at: 1), in: body).map { body[$0].replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") }
        }
    }

    private static func tomlLine(_ items: [String]) -> String {
        "notify = [" + items.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            .joined(separator: ", ") + "]"
    }

    private static func readCodex() -> [String] {
        ((try? String(contentsOf: codexFile, encoding: .utf8)) ?? "").components(separatedBy: "\n")
    }

    private static func writeCodex(_ lines: [String]) throws {
        backup(codexFile)
        try FileManager.default.createDirectory(at: codexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: codexFile, atomically: true, encoding: .utf8)
    }

    private static func installCodex() throws {
        guard !isInstalled(.codex) else { return }
        var lines = readCodex()
        var previous: [String] = []
        if let i = notifyLine(lines) {
            guard let items = tomlStrings(lines[i]) else {
                throw HookError.unreadable(T("config.toml의 notify 설정을 읽을 수 없습니다 (한 줄 배열만 지원)", "Can't read notify in config.toml (single-line array only)"))
            }
            previous = items
            lines.remove(at: i)
            lines.insert(tomlLine([exe, "--agent-done=codex", "--chain"] + previous + ["--end-chain"]), at: i)
        } else {
            lines.insert(tomlLine([exe, "--agent-done=codex"]), at: 0)
        }
        try writeCodex(lines)
    }

    private static func uninstallCodex() throws {
        var lines = readCodex()
        guard let i = notifyLine(lines), lines[i].contains("--agent-done=codex"), let items = tomlStrings(lines[i]) else { return }
        // 원래 notify 명령이 있었으면 되돌린다
        if let a = items.firstIndex(of: "--chain"), let b = items.firstIndex(of: "--end-chain"), a < b, b > a + 1 {
            lines[i] = tomlLine(Array(items[(a + 1)..<b]))
        } else {
            lines.remove(at: i)
        }
        try writeCodex(lines)
    }
}

#if DEV
/// 개발용: `--agent-probe` 훅 설치·해제와 Antigravity 훅 입력을 임시 폴더에서 확인한다 (실제 설정 파일은 건드리지 않음)
enum AgentProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--agent-probe") else { return }
        var checks = 0, failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures.append(what) }
        }
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("dmn-agent-probe-" + UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        AgentHooks.testHome = home
        let file = AgentHooks.antigravityFile, bak = file.appendingPathExtension("dynamicmacnotch.bak")
        func json() -> [String: Any] { (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }

        check(!AgentHooks.isInstalled(.antigravity), "nothing installed at first")
        try? AgentHooks.install(.antigravity)
        let handler = ((json()["dynamic-macnotch"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first
        check(AgentHooks.isInstalled(.antigravity) && json().count == 1, "installs one hook into a new file")
        check(handler?["type"] as? String == "command" && (handler?["command"] as? String)?.hasSuffix("\" --agent-done=antigravity") == true, "Stop handler runs this app")
        try? AgentHooks.uninstall(.antigravity)
        check(!AgentHooks.isInstalled(.antigravity) && json().isEmpty, "removes its own hook")

        let mine = #"{"my-hook": {"enabled": false, "PostToolUse": [{"matcher": "run_command", "hooks": [{"command": "./lint.sh"}]}]}}"#
        try? mine.write(to: file, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: bak)
        let before = json()["my-hook"] as? NSDictionary
        try? AgentHooks.install(.antigravity)
        check(json().count == 2 && (json()["my-hook"] as? NSDictionary) == before, "keeps the user's hooks")
        check((try? String(contentsOf: bak, encoding: .utf8)) == mine, "backs the original up first")
        let once = try? Data(contentsOf: file)
        try? AgentHooks.install(.antigravity)
        check((try? Data(contentsOf: file)) == once, "installing twice changes nothing")
        try? AgentHooks.uninstall(.antigravity)
        check(json().count == 1 && (json()["my-hook"] as? NSDictionary) == before, "removing keeps the user's hooks")

        let broken = "{ not json"
        try? broken.write(to: file, atomically: true, encoding: .utf8)
        var threw = false
        do { try AgentHooks.install(.antigravity) } catch { threw = true }
        check(threw && (try? String(contentsOf: file, encoding: .utf8)) == broken, "an unreadable file is left alone")
        try? "".write(to: file, atomically: true, encoding: .utf8)
        try? AgentHooks.install(.antigravity)
        check(AgentHooks.isInstalled(.antigravity), "an empty file counts as no hooks")

        // 파일이 다른 곳을 가리키는 링크면 링크를 유지한다
        let real = home.appendingPathComponent("dotfiles-hooks.json")
        try? fm.removeItem(at: file)
        try? mine.write(to: real, atomically: true, encoding: .utf8)
        try? fm.createSymbolicLink(at: file, withDestinationURL: real)
        try? AgentHooks.install(.antigravity)
        check((try? fm.destinationOfSymbolicLink(atPath: file.path)) != nil && AgentHooks.isInstalled(.antigravity), "a linked file stays a link")

        for s in [AgentSource.claude, .codex] {
            try? AgentHooks.install(s)
            check(AgentHooks.isInstalled(s), "\(s.name) still installs")
            try? AgentHooks.uninstall(s)
            check(!AgentHooks.isInstalled(s), "\(s.name) still uninstalls")
        }

        // 질문 훅 설치: 사용자의 다른 훅은 그대로, 예전 연결은 '다시 연결'로 질문 훅만 더한다
        let claude = AgentHooks.claudeFile
        try? fm.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs = #"{"model":"x","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"./guard.sh"}]}]}}"#
        try? theirs.write(to: claude, atomically: true, encoding: .utf8)
        try? AgentHooks.install(.claude)
        func claudeJSON() -> [String: Any] { (try? Data(contentsOf: claude)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
        let ch = claudeJSON()["hooks"] as? [String: Any] ?? [:]
        let pre = ch["PreToolUse"] as? [[String: Any]] ?? []
        check(AgentHooks.isInstalled(.claude) && AgentHooks.isAskInstalled(.claude) && claudeJSON()["model"] as? String == "x", "Claude: done and question hooks, other settings kept")
        check(pre.count == 3 && pre.contains { $0["matcher"] as? String == "AskUserQuestion" } && pre.contains { $0["matcher"] as? String == "Bash" }, "Claude: question hook next to the user's hook")
        let askGroup = pre.first { $0["matcher"] as? String == "AskUserQuestion" }
        check((ch["PermissionRequest"] as? [[String: Any]])?.count == 1 && (((askGroup?["hooks"] as? [[String: Any]])?.first?["timeout"]) as? Int) == AgentAsk.hookTimeout, "Claude: permission hook, long timeout")
        let liveHandlers = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"].compactMap { event in
            (ch[event] as? [[String: Any]])?.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.first { (($0["command"] as? String) ?? "").contains("--agent-live=claude") }
        }
        check(AgentHooks.isLiveInstalled(.claude) && liveHandlers.count == 5 && liveHandlers.allSatisfy { $0["async"] as? Bool == true }, "Claude: live hooks on five events, async so Claude never waits")
        try? AgentHooks.uninstall(.claude)
        let back = claudeJSON()["hooks"] as? [String: Any] ?? [:]
        check(!AgentHooks.isInstalled(.claude) && !AgentHooks.isAskInstalled(.claude) && back.count == 1 && (back["PreToolUse"] as? [[String: Any]])?.count == 1, "Claude: removes only its own hooks")
        let old = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/old/DynamicMacNotch --agent-done=claude"}]}]}}"#
        try? old.write(to: claude, atomically: true, encoding: .utf8)
        check(AgentHooks.needsUpdate(.claude), "Claude: an older connection asks to reconnect")
        try? AgentHooks.install(.claude)
        let stops = ((claudeJSON()["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        check(!AgentHooks.needsUpdate(.claude) && stops.filter { (($0["command"] as? String) ?? "").contains("--agent-done=claude") }.count == 1, "Claude: reconnecting adds only what's missing")
        try? AgentHooks.install(.codex)
        let codexHooks = (try? Data(contentsOf: AgentHooks.codexHooksFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check(AgentHooks.isAskInstalled(.codex) && ((codexHooks?["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.count == 1, "Codex: permission hook in hooks.json")
        check(AgentHooks.isLiveInstalled(.codex) && ((codexHooks?["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.count == 1, "Codex: live hooks in hooks.json")
        try? AgentHooks.uninstall(.codex)
        check(!AgentHooks.isAskInstalled(.codex) && !AgentHooks.isInstalled(.codex), "Codex: both removed")
        try? fm.removeItem(at: AgentHooks.antigravityFile)
        try? AgentHooks.install(.antigravity)
        let ag = json()["dynamic-macnotch"] as? [String: Any] ?? [:]
        check(ag["Stop"] != nil && ((ag["PreToolUse"] as? [[String: Any]])?.first?["matcher"] as? String) == "ask_question" && ag["PostToolUse"] != nil, "Antigravity: Stop and question hooks")
        check(AgentHooks.isLiveInstalled(.antigravity) && (ag["PreInvocation"] as? [[String: Any]])?.count == 1 && (ag["Stop"] as? [[String: Any]])?.count == 2
              && (ag["PreToolUse"] as? [[String: Any]])?.count == 2, "Antigravity: live hooks next to the others")

        // 실시간 작업: 훅 입력 → 사건
        let claudeBash = AgentLive.event(from: ["hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/w/Proj", "tool_name": "Bash",
                                                "tool_input": ["command": "swift build", "description": "Built and ran all probes"]], source: .claude)
        check(claudeBash == AgentLive.Event(source: .claude, session: "s1", phase: .toolStart, label: "Built and ran all probes", project: "Proj"), "live: Claude's own description is the label")
        check(AgentLive.toolLabel("Read", ["file_path": "/a/b/Main.swift"]) == T("Main.swift 읽기", "Read Main.swift") && AgentLive.toolLabel("Bash", ["command": "ls -la"]) == "ls -la"
              && AgentLive.toolLabel("mcp__github__create_issue", [:]) == "github · create_issue" && AgentLive.toolLabel("Bash", ["command": ["git", "status"]]) == "git status", "live: labels for tools without a description")
        let agTool = AgentLive.event(from: ["hookEventName": "PreToolUse", "conversationId": "c1", "workspacePaths": ["/w/App"],
                                            "toolCall": ["name": "run_command", "args": ["CommandLine": "ls", "toolSummary": "List workspace directory contents"]]], source: .antigravity)
        check(agTool?.label == "List workspace directory contents" && agTool?.session == "c1" && agTool?.project == "App", "live: Antigravity's toolSummary (real agy 1.5.17 input)")
        check(AgentLive.antigravityLabel(["name": "read_file", "args": ["Path": "/w/App/note.txt"]]) == "note.txt" && AgentLive.antigravityLabel(["name": "list_dir", "args": [:]]) == "list dir", "live: Antigravity labels without a summary")
        check(AgentLive.event(from: ["hookEventName": "PreInvocation", "invocationNum": 0], source: .antigravity)?.phase == .prompt
              && AgentLive.event(from: ["hookEventName": "PreInvocation", "invocationNum": 2], source: .antigravity)?.phase == .toolEnd, "live: only Antigravity's first invocation is a new request")
        check(AgentLive.event(from: ["hook_event_name": "Notification"], source: .claude) == nil && AgentLive.event(from: ["hook_event_name": "SessionEnd", "session_id": "x"], source: .claude)?.phase == .stop, "live: other events")

        // 실시간 작업: 세션 상태
        let live = AgentLiveStore()
        let t0 = Date()
        live.apply(source: .claude, session: "a", phase: .prompt, label: "", project: "P", target: nil, now: t0)
        check(live.sessions.count == 1 && live.sessions.first?.working == false && live.sessions.first?.recent.isEmpty == true, "live: a new request is thinking")
        check(AgentLive.event(from: ["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": "fix the build"], source: .claude)?.label == "fix the build"
              && AgentLive.event(from: ["hookEventName": "PreInvocation", "invocationNum": 0, "lastUserInput": "list files"], source: .antigravity)?.label == "list files", "live: the request text is kept for the finished alert")
        live.apply(source: .claude, session: "r", phase: .prompt, label: "ship it", project: "R", target: nil, now: t0)
        check(live.sessions.first { $0.key == "r" }?.request == "ship it", "live: request stored")
        var viewed = false
        live.isViewing = { viewed }
        live.apply(source: .claude, session: "r", phase: .stop, label: "", project: "R", target: nil, now: t0)
        check(live.shouldPostDone(.claude, project: "R"), "live: not viewing, the usual finished alert decides")
        live.apply(source: .claude, session: "r", phase: .prompt, label: "again", project: "R", target: nil, now: t0)
        viewed = true
        live.apply(source: .claude, session: "r", phase: .stop, label: "", project: "R", target: nil, now: t0)
        check(!live.shouldPostDone(.claude, project: "R") && live.shouldPostDone(.codex, project: "R"), "live: viewing, the detailed alert replaces the usual one")
        live.isViewing = nil
        for (i, label) in ["one", "two", "two", "three", "four", "five"].enumerated() {
            live.apply(source: .claude, session: "a", phase: .toolStart, label: label, project: "P", target: nil, now: t0.addingTimeInterval(Double(i + 1)))
        }
        check(live.sessions.first?.working == true && live.sessions.first?.action == "five" && live.sessions.first?.recent == ["five", "four", "three", "two"], "live: working, newest first, repeats folded, four kept")
        live.apply(source: .claude, session: "a", phase: .toolEnd, label: "", project: "P", target: nil, now: t0.addingTimeInterval(10))
        live.apply(source: .codex, session: "b", phase: .toolStart, label: "npm test", project: "Q", target: "com.apple.Terminal|1", now: t0.addingTimeInterval(20))
        check(live.sessions.first?.working == false && live.ordered.first?.source == .codex && live.ordered.count == 2, "live: back to thinking; the latest session comes first")
        live.apply(source: .claude, session: "a", phase: .prompt, label: "", project: "P", target: nil, now: t0.addingTimeInterval(30))
        check(live.sessions.first { $0.key == "a" }?.recent.isEmpty == true, "live: the next request starts a fresh list")
        live.apply(source: .codex, session: "b", phase: .stop, label: "", project: "Q", target: nil, now: t0.addingTimeInterval(40))
        check(live.sessions.map(\.key) == ["a"], "live: a finished turn disappears")
        check(AgentLivePage.contentHeight([]) == 60 && AgentLivePage.contentHeight(live.ordered) > 40, "live: popup height")

        // 훅 입력 → 질문
        let askInput: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/w/Proj",
                                       "tool_input": ["questions": [["question": "Pick a color", "header": "Color", "multiSelect": false,
                                                                     "options": [["label": "Red", "description": "Choose red"], ["label": "Green", "description": ""]]]]]]
        let ask = AgentAsk.request(from: askInput, source: .claude)
        check(ask?.kind == .question && ask?.project == "Proj" && ask?.questions.first?.options.map(\.label) == ["Red", "Green"] && ask?.questions.first?.header == "Color", "question from AskUserQuestion")
        let bash: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "rm -rf build"]]
        check(AgentAsk.request(from: bash, source: .codex)?.kind == .permission && AgentAsk.request(from: bash, source: .codex)?.detail == "rm -rf build", "permission from PermissionRequest")
        check(AgentAsk.request(from: ["hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion"], source: .claude) == nil
              && AgentAsk.request(from: ["hook_event_name": "PreToolUse", "tool_name": "Bash"], source: .claude) == nil
              && AgentAsk.request(from: ["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": [:]], source: .claude) == nil, "other hooks are left alone")
        check(AgentAsk.permissionDetail(["command": ["git", "push"]]) == "git push" && AgentAsk.permissionDetail(["file_path": "/a/b"]) == "/a/b", "permission detail")
        let notice = AgentAsk.antigravityNotice(from: ["toolCall": ["name": "ask_question", "args": #"{"questions":[{"question":"Which?","options":["A","B"],"is_multi_select":true}]}"#], "workspacePaths": ["/w/App"]])
        check(notice?.kind == .notice && notice?.questions.first?.multiSelect == true && notice?.questions.first?.options.count == 2 && notice?.project == "App", "Antigravity question notice")

        // 답 → 에이전트에 돌려줄 출력
        func object(_ s: String?) -> [String: Any] { s.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:] }
        if let ask {
            let out = object(AgentAsk.output(for: .init(kind: .answer, answers: ["Pick a color": "Green"]), request: ask, input: askInput))["hookSpecificOutput"] as? [String: Any]
            let updated = out?["updatedInput"] as? [String: Any]
            check(out?["permissionDecision"] as? String == "allow" && (updated?["answers"] as? [String: String]) == ["Pick a color": "Green"] && (updated?["questions"] as? [Any])?.count == 1, "answer keeps the questions and adds answers")
            check(AgentAsk.output(for: .init(kind: .release), request: ask, input: askInput) == nil, "release writes nothing")
        }
        if let perm = AgentAsk.request(from: bash, source: .claude) {
            let deny = (object(AgentAsk.output(for: .init(kind: .deny, message: "use make clean"), request: perm, input: bash))["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
            check(deny?["behavior"] as? String == "deny" && deny?["message"] as? String == "use make clean", "deny with what to do instead")
            check(((object(AgentAsk.output(for: .init(kind: .allow), request: perm, input: bash))["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String == "allow", "allow")
        }

        // 실제 훅 프로세스: 질문 → (시험 통로의 본 앱 역할) 답 → 표준 출력. 본 앱이 없으면 바로 끝난다.
        func runHook(_ input: [String: Any], answer: AgentAsk.Reply?, ackPID: pid_t? = nil) -> (out: String, seconds: Double, request: AgentAsk.Request?) {
            let channel = "probe-" + UUID().uuidString.prefix(8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath!)
            p.arguments = ["--agent-ask=claude"]
            p.environment = ProcessInfo.processInfo.environment.merging(["DMN_ASK_CHANNEL": String(channel)]) { $1 }
            let stdin = Pipe(), stdout = Pipe()
            p.standardInput = stdin
            p.standardOutput = stdout
            let dnc = DistributedNotificationCenter.default()
            var seen: AgentAsk.Request?
            let folder = AgentAsk.folder.deletingLastPathComponent().appendingPathComponent("agent-ask." + channel)
            let token = dnc.addObserver(forName: Notification.Name("com.dynamicmacnotch.app.agent-ask." + channel), object: nil, queue: .main) { note in
                guard let id = note.object as? String else { return }
                if let ackPID, answer == nil {
                    // 본 앱이 받았다고 답만 하고 답은 주지 않는다 (그 뒤 앱이 끝나는 경우)
                    dnc.postNotificationName(Notification.Name("com.dynamicmacnotch.app.agent-ask-ack." + channel), object: id, userInfo: ["pid": Int(ackPID)], deliverImmediately: true)
                    return
                }
                guard let answer else { return }
                seen = AgentAsk.read(AgentAsk.Request.self, from: folder.appendingPathComponent("\(id).request.json"))
                dnc.postNotificationName(Notification.Name("com.dynamicmacnotch.app.agent-ask-ack." + channel), object: id, userInfo: nil, deliverImmediately: true)
                AgentAsk.write(answer, to: folder.appendingPathComponent("\(id).reply.json"))
            }
            let start = Date()
            try? p.run()
            stdin.fileHandleForWriting.write((try? JSONSerialization.data(withJSONObject: input)) ?? Data())
            try? stdin.fileHandleForWriting.close()
            while p.isRunning, Date().timeIntervalSince(start) < 8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            if p.isRunning { p.terminate() }
            dnc.removeObserver(token)
            let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let left = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            check(left.isEmpty, "hook cleans up its files: \(left)")
            try? fm.removeItem(at: folder)
            return (out, Date().timeIntervalSince(start), seen)
        }
        let answered = runHook(askInput, answer: .init(kind: .answer, answers: ["Pick a color": "Red"]))
        let answeredOut = object(answered.out.trimmingCharacters(in: .whitespacesAndNewlines))["hookSpecificOutput"] as? [String: Any]
        check(((answeredOut?["updatedInput"] as? [String: Any])?["answers"] as? [String: String]) == ["Pick a color": "Red"], "hook returns the notch's answer: \(answered.out.prefix(80))")
        check(answered.request?.questions.first?.question == "Pick a color" && answered.request?.hookPID ?? 0 > 0, "the app reads the question from the file")
        let typed = runHook(askInput, answer: .init(kind: .answer, answers: ["Pick a color": "something else"]))
        check(typed.out.contains("something else"), "typed answer goes through")
        let released = runHook(askInput, answer: .init(kind: .release))
        check(released.out.isEmpty, "released: the agent asks in its own screen")
        let noApp = runHook(askInput, answer: nil)
        check(noApp.out.isEmpty && noApp.seconds < 3, "no app: gives up quickly (\(String(format: "%.1f", noApp.seconds))s)")
        // F-1: 본 앱이 받은 뒤 끝나면(다시 시작·종료·충돌) 10분을 기다리지 않고 원래 화면으로
        let shortLived = Process()
        shortLived.executableURL = URL(fileURLWithPath: "/bin/sleep")
        shortLived.arguments = ["1.5"]
        try? shortLived.run()
        let appGone = runHook(askInput, answer: nil, ackPID: shortLived.processIdentifier)
        check(appGone.out.isEmpty && appGone.seconds < 4, "app ends while waiting: gives up at once (\(String(format: "%.1f", appGone.seconds))s)")

        // F-2: 훅 소식은 파일로, 알림에는 id만. 가리기.
        let channelDir = fm.temporaryDirectory.appendingPathComponent("dmn-channel-" + UUID().uuidString)
        try? fm.createDirectory(at: channelDir, withIntermediateDirectories: true)
        let probeNote = Notification.Name("com.dynamicmacnotch.app.probe-" + UUID().uuidString)
        var received: Notification?
        let probeToken = DistributedNotificationCenter.default().addObserver(forName: probeNote, object: nil, queue: .main) { received = $0 }
        AgentChannel.post(probeNote, object: "claude", payload: ["task": "secret plan", "pid": 7], in: channelDir)
        let until = Date().addingTimeInterval(3)
        while received == nil, Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        DistributedNotificationCenter.default().removeObserver(probeToken)
        check(received?.userInfo?.count == 1 && received?.userInfo?["id"] != nil && received?.userInfo?["task"] == nil, "the notification carries only an id")
        let files = (try? fm.contentsOfDirectory(atPath: channelDir.path)) ?? []
        let mode = files.first.flatMap { (try? fm.attributesOfItem(atPath: channelDir.appendingPathComponent($0).path)[.posixPermissions]) as? Int }
        check(files.count == 1 && mode == 0o600, "the text is in a file only this user can read (\(String(mode ?? 0, radix: 8)))")
        let taken = received.flatMap { AgentChannel.take($0, in: channelDir) }
        check(taken?["task"] as? String == "secret plan" && taken?["pid"] as? Int == 7 && ((try? fm.contentsOfDirectory(atPath: channelDir.path)) ?? []).isEmpty, "reading removes the file")
        check(AgentChannel.take(Notification(name: probeNote, object: nil, userInfo: ["id": "../../etc/passwd"]), in: channelDir) == nil
              && AgentChannel.take(Notification(name: probeNote, object: nil, userInfo: nil), in: channelDir) == nil, "only UUID ids are read")
        let stale = channelDir.appendingPathComponent(UUID().uuidString + ".json"), fresh = channelDir.appendingPathComponent(UUID().uuidString + ".json")
        fm.createFile(atPath: stale.path, contents: Data("{}".utf8))
        fm.createFile(atPath: fresh.path, contents: Data("{}".utf8))
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        check(AgentChannel.sweep(channelDir, olderThan: 60) == 1 && fm.fileExists(atPath: fresh.path) && !fm.fileExists(atPath: stale.path), "F-3: sweeping removes only old files")
        try? fm.removeItem(at: channelDir)
        let redactions: [(String, String)] = [
            ("curl -H \"Authorization: Bearer abc.def.ghi\" https://x", "curl -H \"Authorization: Bearer •••\" https://x"),
            ("mysql --password=hunter2 -u root", "mysql --password=••• -u root"),
            ("export API_KEY=xyz123 && run", "export API_KEY=••• && run"),
            ("git clone https://me:tok3n@github.com/a/b", "git clone https://me:•••@github.com/a/b"),
            ("use sk-ant-REDACTED_TEST_KEY_0000 now", "use ••• now"),
            ("swift build -c release", "swift build -c release"),
        ]
        for (input, want) in redactions { check(AgentChannel.redact(input) == want, "redact: \(want)") }
        check(AgentLive.event(from: ["hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "Bash", "tool_input": ["command": "TOKEN=abc123 deploy"]], source: .claude)?.label == "TOKEN=••• deploy", "live labels are redacted")
        check(AgentAsk.isValidID(UUID().uuidString) && !AgentAsk.isValidID("../x"), "question ids are UUIDs")

        func stop(_ s: String) -> (folder: String?, task: String, failed: Bool)? { AgentNotify.antigravityStop(Data(s.utf8)) }
        let done = stop(#"{"workspacePaths":["/a/Proj","/b"],"lastUserInput":"fix it","terminationReason":"model_stop","fullyIdle":true,"executionNum":1}"#)
        check(done?.folder == "/a/Proj" && done?.task == "fix it" && done?.failed == false, "finished turn")
        check(stop(#"{"fullyIdle":false,"terminationReason":"model_stop"}"#) == nil, "not finished while background work runs")
        check(stop(#"{"fullyIdle":true,"terminationReason":"error","error":"x"}"#)?.failed == true, "error is told apart")
        check(stop(#"{"fullyIdle":true,"workspacePaths":[]}"#)?.folder == nil, "no workspace")
        let actual = stop(#"{"fullyIdle":true,"workspacePaths":[],"cwd":"/c","terminationReason":"NO_TOOL_CALL","error":"","lastUserInput":"q"}"#)
        check(actual?.failed == false && actual?.folder == "/c", "real agy 1.5.17 input")
        check(stop(#"{"fullyIdle":true,"terminationReason":"ERROR"}"#)?.failed == true, "upper-case error")
        check(stop("garbage") == nil, "unreadable input is ignored")

        AgentHooks.testHome = nil
        try? fm.removeItem(at: home)
        print("agent checks=\(checks) failures=\(failures.count)")
        failures.forEach { print("  FAIL", $0) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
#endif
