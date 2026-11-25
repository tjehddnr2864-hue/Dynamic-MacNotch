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
            SettingsSection(SectionTitle.style, footer: T("컴팩트는 아이콘과 '완료'만 보입니다.", "Compact shows only the icon and Done."), more: T("상세는 '에이전트 · 프로젝트'와 함께 끝난 작업(마지막으로 보낸 요청)을 한 줄로 보여 줍니다. 컴팩트는 아이콘과 '완료'만 보이고, 길게 누르면 상세로 볼 수 있습니다.",
                                                         "Detailed shows 'Agent · project' and the finished task (your last request) on one line. Compact shows only the icon and Done; long-press it to see the details."),
                            disabled: !settings.agentAlerts, disabledNote: T("작업 완료 알림을 켜면 바꿀 수 있습니다.", "Turn on Task finished alert to change this.")) {
                AlertStylePicker(selection: $settings.agentStyle)
            }
            SettingsSection(T("연결", "Connection"), footer: T("각 도구의 설정 파일에 알림을 넣습니다. 원본은 백업합니다.", "Adds a notification to each tool's settings file. The original is backed up."), more: T("연결하면 Claude Code는 ~/.claude/settings.json에 '작업 완료(Stop)' 훅을, Codex는 ~/.codex/config.toml의 notify에, Antigravity는 ~/.gemini/config/hooks.json의 Stop 훅에 이 앱을 넣습니다. Codex에 이미 notify가 있으면 그 명령도 그대로 이어서 실행되고, 연결 해제 시 원래대로 돌려놓습니다. 처음 바꾸기 전 원본은 .dynamicmacnotch.bak으로 남깁니다. Antigravity의 다른 훅은 그대로 둡니다. 새로 시작한 세션부터 적용됩니다.",
                                                           "Connecting adds a Stop hook to ~/.claude/settings.json for Claude Code, sets notify in ~/.codex/config.toml for Codex, and adds a Stop hook to ~/.gemini/config/hooks.json for Antigravity. If Codex already has a notify command, it still runs, and disconnecting restores it. The original file is kept as .dynamicmacnotch.bak before the first change. Your other Antigravity hooks stay as they are. Applies to new sessions.")) {
                ForEach(AgentSource.allCases) { source in
                    let installed = AgentHooks.isInstalled(source)
                    LabeledContent {
                        HStack(spacing: 8) {
                            StatusText(text: installed ? T("연결됨", "Connected") : T("연결 안 됨", "Not connected"), good: installed)
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
