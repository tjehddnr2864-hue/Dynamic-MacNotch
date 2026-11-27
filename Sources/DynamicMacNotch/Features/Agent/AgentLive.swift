import AppKit
import Combine
import SwiftUI

/// 코딩 에이전트의 실시간 작업 (상시 표시 '에이전트 작업').
///
/// 에이전트의 훅(요청 받음·도구 시작·도구 끝·턴 끝)이 이 앱 실행 파일을 `--agent-live=<에이전트>`로 잠깐 실행하고,
/// 그 짧은 프로세스가 분산 알림으로 본 앱에 알린 뒤 바로 끝난다. 에이전트의 동작은 바꾸지 않는다.
/// - 접힌 노치: 왼쪽 에이전트 아이콘, 오른쪽 '생각 중'·'작업 중'
/// - 길게 눌러 연 팝업: 세션마다 지금 하는 작업의 이름과 바로 앞 작업들 (Claude Code의 도구 설명, Antigravity의 toolSummary 등)
enum AgentLive {
    static let note = Notification.Name("com.dynamicmacnotch.app.agent-live")

    static func source(from arguments: [String]) -> AgentSource? {
        arguments.first { $0.hasPrefix("--agent-live=") }.flatMap { AgentSource(rawValue: String($0.dropFirst("--agent-live=".count))) }
    }

    enum Phase: String { case prompt, toolStart, toolEnd, stop }

    struct Event: Equatable {
        var source: AgentSource
        var session: String
        var phase: Phase
        /// 도구를 시작할 때: 사람이 읽을 작업 이름
        var label: String
        var project: String
    }

    // MARK: 훅 입력 → 사건

    /// Claude Code·Codex·Antigravity의 훅 입력에서 사건을 만든다. 다룰 것이 아니면 nil.
    static func event(from input: [String: Any], source: AgentSource) -> Event? {
        let name = input["hook_event_name"] as? String ?? input["hookEventName"] as? String ?? ""
        let phase: Phase
        switch name {
        case "UserPromptSubmit": phase = .prompt
        // Antigravity는 모델을 부를 때마다 온다: 첫 번째만 새 요청, 나머지는 도구를 쓴 뒤 다시 생각하는 것
        case "PreInvocation": phase = (input["invocationNum"] as? Int ?? 0) > 0 ? .toolEnd : .prompt
        case "PreToolUse": phase = .toolStart
        case "PostToolUse": phase = .toolEnd
        case "Stop", "SessionEnd": phase = .stop
        default: return nil
        }
        let session = input["session_id"] as? String ?? input["conversationId"] as? String ?? ""
        let folder = input["cwd"] as? String ?? (input["workspacePaths"] as? [String])?.first ?? FileManager.default.currentDirectoryPath
        var label = ""
        if phase == .prompt {
            // 요청 내용 (작업 완료 알림에 쓴다)
            label = input["prompt"] as? String ?? input["lastUserInput"] as? String ?? ""
        } else if phase == .toolStart {
            if let call = input["toolCall"] as? [String: Any] {
                label = antigravityLabel(call)
            } else {
                label = toolLabel(input["tool_name"] as? String ?? "", input["tool_input"] as? [String: Any] ?? [:])
            }
        }
        return Event(source: source, session: session, phase: phase, label: AgentNotify.oneLine(label, limit: 90),
                     project: URL(fileURLWithPath: folder).lastPathComponent)
    }

    /// Claude Code·Codex 도구의 이름. 에이전트가 적은 설명(description)이 있으면 그것을 쓴다.
    static func toolLabel(_ tool: String, _ input: [String: Any]) -> String {
        func text(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func file(_ key: String) -> String? { text(key).map { URL(fileURLWithPath: $0).lastPathComponent } }
        if let d = text("description") { return d }
        switch tool {
        case "Bash", "shell", "exec_command", "local_shell":
            if let c = text("command") { return c }
            if let parts = input["command"] as? [String] { return parts.joined(separator: " ") }
            return T("명령 실행", "Run a command")
        case "Read": return T("\(file("file_path") ?? "파일") 읽기", "Read \(file("file_path") ?? "a file")")
        case "Write": return T("\(file("file_path") ?? "파일") 작성", "Write \(file("file_path") ?? "a file")")
        case "Edit", "MultiEdit", "NotebookEdit":
            let f = file("file_path") ?? file("notebook_path")
            return T("\(f ?? "파일") 편집", "Edit \(f ?? "a file")")
        case "apply_patch": return T("파일 편집", "Edit files")
        case "Grep": return T("'\(text("pattern") ?? "")' 찾기", "Search for '\(text("pattern") ?? "")'")
        case "Glob": return T("\(text("pattern") ?? "") 파일 찾기", "Find \(text("pattern") ?? "files")")
        case "WebFetch":
            let host = text("url").flatMap { URL(string: $0)?.host } ?? ""
            return T("\(host) 읽기", "Fetch \(host)")
        case "WebSearch": return T("'\(text("query") ?? "")' 웹 검색", "Search the web for '\(text("query") ?? "")'")
        case "TodoWrite": return T("할 일 정리", "Update to-dos")
        case "AskUserQuestion": return T("질문하는 중", "Asking you")
        case "Task", "Agent": return T("하위 에이전트 작업", "Subagent task")
        default:
            // mcp__server__tool → server · tool
            if tool.hasPrefix("mcp__") { return tool.dropFirst(5).components(separatedBy: "__").joined(separator: " · ") }
            return tool
        }
    }

    /// Antigravity 도구의 이름: toolSummary(에이전트가 적은 설명) → 명령·파일·검색어 → 도구 이름
    static func antigravityLabel(_ call: [String: Any]) -> String {
        var args = call["args"] as? [String: Any]
        if args == nil, let s = call["args"] as? String, let data = s.data(using: .utf8) { args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
        let a = args ?? [:]
        func text(_ keys: String...) -> String? {
            keys.lazy.compactMap { a[$0] as? String }.first { !$0.isEmpty }
        }
        if let summary = text("toolSummary") { return summary }
        if let command = text("CommandLine", "command") { return command }
        if let path = text("AbsolutePath", "TargetFile", "Path", "path", "file_path") { return URL(fileURLWithPath: path).lastPathComponent }
        if let query = text("Query", "query", "Url", "url") { return query }
        return (call["name"] as? String ?? "").replacingOccurrences(of: "_", with: " ")
    }

    // MARK: 훅 쪽 (짧게 실행되고 끝남)

    static func runHook(_ source: AgentSource) -> Never {
        let data = (try? FileHandle.standardInput.readToEnd()) ?? Data()
        let input = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        // 에이전트의 동작은 바꾸지 않는다 (Antigravity는 결정을 꼭 돌려줘야 한다)
        if source == .antigravity {
            let name = input["hookEventName"] as? String ?? ""
            let reply = name == "PreToolUse" ? "{\"decision\":\"allow\"}" : name == "Stop" ? "{\"decision\":\"stop\"}" : "{}"
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
        // 노치 채팅이 띄운 CLI는 알리지 않는다
        guard ProcessInfo.processInfo.environment["DMN_CHAT"] == nil, let e = event(from: input, source: source) else { exit(0) }
        let host = AgentNotify.guiHost()
        DistributedNotificationCenter.default().postNotificationName(note, object: source.rawValue, userInfo: [
            "session": e.session, "phase": e.phase.rawValue, "label": e.label, "project": e.project,
            "bundle": host?.bundleIdentifier ?? "", "pid": Int(host?.processIdentifier ?? 0),
        ], deliverImmediately: true)
        exit(0)
    }
}

// MARK: - 본 앱 쪽

/// 지금 일하고 있는 에이전트 세션들. 가장 최근에 움직인 세션을 노치에 상시 표시한다.
final class AgentLiveStore: ObservableObject {
    static let shared = AgentLiveStore()

    struct Session: Identifiable, Equatable {
        var id: String { "\(source.rawValue)|\(key)" }
        var source: AgentSource
        var key: String
        var project: String
        var working: Bool
        /// 지금(또는 마지막) 작업 이름
        var action: String
        /// 이번 요청에서 한 작업들 (최근 것이 앞)
        var recent: [String]
        /// 이번 요청 내용
        var request = ""
        var started: Date
        var updated: Date
        var target: String?
    }

    @Published private(set) var sessions: [Session] = []
    private weak var center: ActivityCenter?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    /// 이만큼 소식이 없으면 끝난 것으로 본다 (긴 명령이 도는 중이면 더 길게)
    static let idleLimit: TimeInterval = 10 * 60, workingLimit: TimeInterval = 30 * 60
    static let recentLimit = 4

    /// 가장 최근에 움직인 순서
    var ordered: [Session] { sessions.sorted { $0.updated > $1.updated } }

    func start(center: ActivityCenter) {
        self.center = center
        observer = DistributedNotificationCenter.default().addObserver(forName: AgentLive.note, object: nil, queue: .main) { [weak self] note in
            guard let self, AppSettings.shared.agentLive, let raw = note.object as? String, let source = AgentSource(rawValue: raw),
                  let info = note.userInfo, let phase = (info["phase"] as? String).flatMap(AgentLive.Phase.init(rawValue:)) else { return }
            let bundle = info["bundle"] as? String ?? "", pid = info["pid"] as? Int ?? 0
            self.apply(source: source, session: info["session"] as? String ?? "", phase: phase, label: info["label"] as? String ?? "",
                       project: info["project"] as? String ?? "", target: bundle.isEmpty ? nil : "\(bundle)|\(pid)")
        }
        // 설정에서 끄면 바로 지운다
        AppSettings.shared.$agentLive.dropFirst().sink { [weak self] on in if !on { self?.clear() } }.store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    func apply(source: AgentSource, session: String, phase: AgentLive.Phase, label: String, project: String, target: String?, now: Date = Date()) {
        let key = session.isEmpty ? project : session
        let index = sessions.firstIndex { $0.source == source && $0.key == key }
        if phase == .stop {
            if let index {
                let ended = sessions.remove(at: index)
                // 작업 팝업을 보고 있던 중에 끝나면: 설정과 상관없이 상세 작업 완료 알림을 띄운다
                if isViewing?() == true { announceFinished(ended) }
            }
            return publish()
        }
        var s = index.map { sessions[$0] } ?? Session(source: source, key: key, project: project, working: false, action: "", recent: [],
                                                       started: now, updated: now, target: target)
        s.updated = now
        if !project.isEmpty { s.project = project }
        if let target { s.target = target }
        switch phase {
        case .prompt:
            // 새 요청: 지난 작업 목록을 비운다
            if !label.isEmpty { s.request = label }
            s.recent = []
            s.action = ""
            s.started = now
            s.working = false
        case .toolStart:
            s.working = true
            if !label.isEmpty {
                s.action = label
                if s.recent.first != label { s.recent.insert(label, at: 0) }
                s.recent = Array(s.recent.prefix(Self.recentLimit))
            }
        case .toolEnd:
            s.working = false
        case .stop:
            break
        }
        if let index { sessions[index] = s } else { sessions.append(s) }
        publish()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.expire() }
        }
    }

    private func expire(now: Date = Date()) {
        let before = sessions.count
        sessions.removeAll { now.timeIntervalSince($0.updated) > ($0.working ? Self.workingLimit : Self.idleLimit) }
        if sessions.count != before { publish() }
    }

    /// 작업 팝업(길게 눌러 연 확장 노치)을 지금 보고 있는지 (AppDelegate가 정한다)
    var isViewing: (() -> Bool)?
    /// 그 팝업을 접는다 (다른 세션이 남아 있어도 완료 알림이 가려지지 않게)
    var closeViewer: (() -> Void)?
    /// 방금 상세 완료 알림을 띄운 세션: 같은 끝남에 대한 작업 완료 훅 알림은 건너뛴다
    private var announced: [(source: AgentSource, project: String, at: Date)] = []

    private func announceFinished(_ s: Session) {
        closeViewer?()
        center?.post(AgentNotify.activity(s.source, project: s.project, task: s.request.isEmpty ? (s.recent.first ?? "") : s.request,
                                          target: s.target, style: .detail))
        announced.append((s.source, s.project, Date()))
        announced.removeAll { Date().timeIntervalSince($0.at) > 10 }
    }

    /// 작업 완료 훅의 알림을 띄워도 되는지 (방금 같은 끝남을 상세로 알렸으면 false)
    func shouldPostDone(_ source: AgentSource, project: String) -> Bool {
        !announced.contains { $0.source == source && $0.project == project && Date().timeIntervalSince($0.at) < 10 }
    }

    func clear() {
        sessions = []
        publish()
    }

    /// 누르면: 가장 최근 세션이 돌던 앱을 연다
    func openHost(_ session: Session? = nil) {
        guard let s = session ?? ordered.first else { return }
        AgentNotify.open(s.target ?? s.source.appBundleID)
    }

    static func stateText(_ s: Session) -> String { s.working ? T("작업 중", "Working") : T("생각 중", "Thinking") }

    private func publish() {
        guard let center else { return }
        if sessions.isEmpty {
            timer?.invalidate()
            timer = nil
            return center.removePersistent(.agentLive)
        }
        guard let s = ordered.first else { return }
        let more = sessions.count > 1 ? " +\(sessions.count - 1)" : ""
        center.setPersistent(NotchActivity(
            kind: .agentLive, priority: ActivityPriority.pinned, symbol: s.source.symbol, tint: s.source.tint,
            value: .text(Self.stateText(s) + more),
            title: s.project.isEmpty ? s.source.name : "\(s.source.name) · \(s.project)",
            subtitle: s.action.isEmpty ? Self.stateText(s) : s.action, targetApp: s.target))
    }

    /// 미리보기: 실제 에이전트 없이 작업 중인 세션 둘을 보인다 (2분 뒤 사라짐)
    func preview() {
        let now = Date()
        apply(source: .claude, session: "preview-1", phase: .prompt, label: T("설정 화면 정리하고 배포 준비", "Tidy the settings and get ready to ship"), project: "DynamicMacNotch", target: nil, now: now)
        for label in [T("설정 화면 규칙 점검", "Check the settings screen rules"), T("README 갱신", "Update the README"), T("빌드하고 점검 실행", "Built and ran all probes")] {
            apply(source: .claude, session: "preview-1", phase: .toolStart, label: label, project: "DynamicMacNotch", target: nil, now: now)
        }
        apply(source: .antigravity, session: "preview-2", phase: .toolStart, label: T("작업 폴더 파일 목록 보기", "List workspace directory contents"),
              project: "WebApp", target: nil, now: now.addingTimeInterval(-5))
        apply(source: .antigravity, session: "preview-2", phase: .toolEnd, label: "", project: "WebApp", target: nil, now: now.addingTimeInterval(-4))
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            self?.sessions.removeAll { $0.key.hasPrefix("preview-") }
            self?.publish()
        }
    }
}

// MARK: - 길게 눌러 연 팝업

/// 세션마다: 에이전트 · 프로젝트 · 상태, 아래에 지금 작업과 바로 앞 작업들
struct AgentLivePage: View {
    @ObservedObject var store: AgentLiveStore

    static let maxSessions = 3, actionRow: CGFloat = 19, sessionHeader: CGFloat = 18, sessionGap: CGFloat = 10

    /// 노치 아래 내용 높이
    static func contentHeight(_ sessions: [AgentLiveStore.Session]) -> CGFloat {
        let shown = Array(sessions.prefix(maxSessions))
        guard !shown.isEmpty else { return 60 }
        let body = shown.reduce(CGFloat(0)) { total, s in
            total + sessionHeader + 4 + CGFloat(max(1, min(3, s.recent.count))) * actionRow
        }
        return 4 + body + CGFloat(shown.count - 1) * sessionGap + 6
    }

    var body: some View {
        let sessions = Array(store.ordered.prefix(Self.maxSessions))
        VStack(alignment: .leading, spacing: Self.sessionGap) {
            ForEach(sessions) { s in
                session(s)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func session(_ s: AgentLiveStore.Session) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { store.openHost(s) } label: {
                HStack(spacing: 6) {
                    Image(systemName: s.source.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(s.source.tint)
                    Text(s.project.isEmpty ? s.source.name : "\(s.source.name) · \(s.project)")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: s.started, by: 1)) { ctx in
                        Text(Self.elapsed(from: s.started, to: ctx.date)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                    }
                    Text(AgentLiveStore.stateText(s)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(s.source.tint)
                }
                .frame(height: Self.sessionHeader)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(T("그 앱 열기", "Open the app"))
            if s.recent.isEmpty {
                actionLine(T("요청을 읽고 생각하는 중", "Reading the request and thinking"), current: true, working: false, tint: s.source.tint)
            } else {
                ForEach(Array(s.recent.prefix(3).enumerated()), id: \.offset) { i, label in
                    actionLine(label, current: i == 0, working: i == 0 && s.working, tint: s.source.tint)
                }
            }
        }
    }

    /// 사진의 밑줄 부분처럼: 작업 이름 + ›  (지금 하는 것은 밝게, 지난 것은 흐리게)
    private func actionLine(_ label: String, current: Bool, working: Bool, tint: Color) -> some View {
        HStack(spacing: 6) {
            Group {
                if working {
                    ProgressView().controlSize(.mini).tint(tint)
                } else {
                    Image(systemName: current ? "circle.dotted" : "checkmark").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(current ? tint : .white.opacity(0.35))
                }
            }
            .frame(width: 12)
            Text(label).font(.system(size: 11.5, weight: current ? .medium : .regular))
                .foregroundStyle(.white.opacity(current ? 0.9 : 0.45)).lineLimit(1)
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(current ? 0.45 : 0.25))
            Spacer(minLength: 0)
        }
        .frame(height: Self.actionRow)
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 3600 ? String(format: "%d:%02d", s / 60, s % 60) : String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}
