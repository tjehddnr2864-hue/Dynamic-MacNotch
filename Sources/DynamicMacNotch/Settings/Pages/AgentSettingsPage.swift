import SwiftUI

/// 코딩 에이전트(Claude Code · Codex · Antigravity) 작업 완료 알림. '연결'을 눌러야만 각 설정 파일에 훅을 넣는다.
struct AgentSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared
    private let refresh = State(initialValue: 0)
    private let errorState = State(initialValue: String?.none)

    var body: some View {
        let _ = refresh.wrappedValue   // 연결·해제 뒤 상태를 다시 읽는다
        SettingsForm {
            SettingsSection(SectionTitle.show) {
                Toggle(T("작업 완료 알림", "Task finished alert"), detail: T("누르면 그 작업이 돌던 앱이 열립니다.", "Click it to open the app the task ran in."), isOn: $settings.agentAlerts)
            }
            SettingsSection(T("질문에 답하기", "Answer Questions"),
                            footer: T("길게 누르면 노치에서 고르고, 누르면 그 앱이 열립니다.", "Long-press to choose in the notch; click to open the app."),
                            more: T("에이전트가 작업 중에 선택지를 묻거나 실행 허락을 구하면 노치에 '질문'·'허락'이 남습니다. 길게 누르면 선택지와 맨 아래 '직접 입력' 칸이 나오고, 고르거나 입력해 보내면 그 답이 에이전트에 전해집니다. 그냥 누르거나 그 앱으로 돌아가면 원래 화면에서 답할 수 있고, 10분 동안 답하지 않아도 원래 화면으로 돌아갑니다. 그 앱을 보고 있을 때는 노치에 띄우지 않습니다.\n\nClaude Code는 선택 질문과 실행 허락, Codex는 실행 허락만 답할 수 있습니다(Codex는 선택 질문에 답하는 훅이 없음). Codex는 처음에 /hooks에서 이 훅을 신뢰해야 동작합니다. Antigravity는 질문을 알리기만 하고, 답은 Antigravity에서 합니다. 질문 내용은 이 Mac 안에서만 주고받습니다.",
                                    "When an agent asks you to pick an option or to allow something while it works, Question or Allow? stays in the notch. Long-press it to see the options and a Type your own answer field at the bottom; what you pick or type goes back to the agent. Click it, or switch to that app, to answer there instead; it also goes back there after 10 minutes. Nothing shows while you're looking at that app.\n\nClaude Code: questions and permissions. Codex: permissions only (it has no hook for answering questions); trust the hook once in /hooks. Antigravity: questions are only shown, and you answer in Antigravity. Questions never leave this Mac."),
                            disabled: AgentSource.allCases.allSatisfy { !AgentHooks.isInstalled($0) }, disabledNote: T("아래에서 연결하면 쓸 수 있습니다.", "Connect an agent below to use this.")) {
                Toggle(T("노치에서 답하기", "Answer in the notch"), detail: T("Claude Code 질문·실행 허락, Codex 실행 허락", "Claude Code questions and permissions, Codex permissions"), isOn: $settings.agentAsk)
            }
            SettingsSection(SectionTitle.style, footer: T("컴팩트는 아이콘과 '완료'만 보입니다.", "Compact shows only the icon and Done."), more: T("상세는 '에이전트 · 프로젝트'와 함께 끝난 작업(마지막으로 보낸 요청)을 한 줄로 보여 줍니다. 컴팩트는 아이콘과 '완료'만 보이고, 길게 누르면 상세로 볼 수 있습니다.",
                                                         "Detailed shows 'Agent · project' and the finished task (your last request) on one line. Compact shows only the icon and Done; long-press it to see the details."),
                            disabled: !settings.agentAlerts, disabledNote: T("작업 완료 알림을 켜면 바꿀 수 있습니다.", "Turn on Task finished alert to change this.")) {
                AlertStylePicker(selection: $settings.agentStyle)
            }
            SettingsSection(T("연결", "Connection"), footer: T("각 도구의 설정 파일에 알림을 넣습니다. 원본은 백업합니다.", "Adds a notification to each tool's settings file. The original is backed up."), more: T("연결하면 Claude Code는 ~/.claude/settings.json에 작업 완료(Stop)·선택 질문(PreToolUse)·실행 허락(PermissionRequest) 훅을, Codex는 ~/.codex/config.toml의 notify와 ~/.codex/hooks.json의 실행 허락 훅을, Antigravity는 ~/.gemini/config/hooks.json에 작업 완료·질문 알림 훅을 넣습니다. Codex에 이미 notify가 있으면 그 명령도 그대로 이어서 실행되고, 연결 해제 시 원래대로 돌려놓습니다. 처음 바꾸기 전 원본은 .dynamicmacnotch.bak으로 남깁니다. Antigravity의 다른 훅은 그대로 둡니다. 새로 시작한 세션부터 적용됩니다.",
                                                           "Connecting adds Stop, PreToolUse (questions) and PermissionRequest hooks to ~/.claude/settings.json for Claude Code, sets notify in ~/.codex/config.toml and adds a PermissionRequest hook to ~/.codex/hooks.json for Codex, and adds task-finished and question hooks to ~/.gemini/config/hooks.json for Antigravity. If Codex already has a notify command, it still runs, and disconnecting restores it. The original file is kept as .dynamicmacnotch.bak before the first change. Your other Antigravity hooks stay as they are. Applies to new sessions.")) {
                ForEach(AgentSource.allCases) { source in
                    let installed = AgentHooks.isInstalled(source)
                    let update = AgentHooks.needsUpdate(source)
                    LabeledContent {
                        HStack(spacing: 8) {
                            StatusText(text: update ? T("다시 연결 필요", "Reconnect to update") : installed ? T("연결됨", "Connected") : T("연결 안 됨", "Not connected"), good: installed && !update)
                            if update {
                                Button(T("다시 연결", "Reconnect")) { toggle(source, installed: false) }
                            }
                            Button(installed ? T("연결 해제", "Disconnect") : T("연결", "Connect")) { toggle(source, installed: installed) }
                        }
                    } label: {
                        Label(source.name, systemImage: source.symbol)
                    }
                }
                if let error = errorState.wrappedValue {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            PreviewSection([(.agentDone, T("작업 완료", "Task Finished"))])
        }
    }

    private func toggle(_ source: AgentSource, installed: Bool) {
        do {
            try installed ? AgentHooks.uninstall(source) : AgentHooks.install(source)
            errorState.wrappedValue = nil
        } catch {
            errorState.wrappedValue = error.localizedDescription
        }
        refresh.wrappedValue += 1
    }
}
