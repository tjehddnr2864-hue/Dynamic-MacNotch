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
        let app = guiAncestor()
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: source.rawValue,
            userInfo: ["project": URL(fileURLWithPath: folder).lastPathComponent,
                       "task": oneLine(task, limit: 80),
                       "failed": failed,
                       "bundle": app?.bundleIdentifier ?? "",
                       "pid": Int(app?.processIdentifier ?? 0)],
            deliverImmediately: true)
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
    private static func guiAncestor() -> NSRunningApplication? {
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
            guard AppSettings.shared.agentAlerts,
                  let raw = note.object as? String, let source = AgentSource(rawValue: raw) else { return }
            let info = note.userInfo ?? [:]
            let project = info["project"] as? String ?? ""
            let bundle = info["bundle"] as? String ?? ""
            let pid = info["pid"] as? Int ?? 0
            let task = info["task"] as? String ?? ""
            let failed = info["failed"] as? Bool ?? false
            // 그 에이전트가 돌던 앱을 지금 보고 있으면 알리지 않는다 (화면이 잠겨 있으면 보고 있는 것이 아님)
            if isViewing(source, bundle: bundle, pid: pid) { return }
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

    static func install(_ s: AgentSource) throws {
        switch s {
        case .claude: try installClaude()
        case .codex: try installCodex()
        case .antigravity: try installAntigravity()
        }
    }

    static func uninstall(_ s: AgentSource) throws {
        switch s {
        case .claude: try uninstallClaude()
        case .codex: try uninstallCodex()
        case .antigravity: try uninstallAntigravity()
        }
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

    private static func installClaude() throws {
        guard !isInstalled(.claude) else { return }
        var obj = try readClaude()
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        var stop = hooks["Stop"] as? [[String: Any]] ?? []
        stop.append(["hooks": [["type": "command", "command": "\"\(exe)\" --agent-done=claude"]]])
        hooks["Stop"] = stop
        obj["hooks"] = hooks
        try writeClaude(obj)
    }

    private static func uninstallClaude() throws {
        var obj = try readClaude()
        guard var hooks = obj["hooks"] as? [String: Any], let stop = hooks["Stop"] as? [[String: Any]] else { return }
        let kept = stop.compactMap { group -> [String: Any]? in
            var g = group
            let list = (g["hooks"] as? [[String: Any]] ?? []).filter { !(($0["command"] as? String) ?? "").contains("--agent-done=claude") }
            if list.isEmpty { return nil }
            g["hooks"] = list
            return g
        }
        if kept.isEmpty { hooks["Stop"] = nil } else { hooks["Stop"] = kept }
        if hooks.isEmpty { obj["hooks"] = nil } else { obj["hooks"] = hooks }
        try writeClaude(obj)
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

    private static func installAntigravity() throws {
        guard !isInstalled(.antigravity) else { return }
        var obj = try readAntigravity()
        obj[antigravityHook] = ["Stop": [["type": "command", "command": "\"\(exe)\" --agent-done=antigravity", "timeout": 10] as [String: Any]]]
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
