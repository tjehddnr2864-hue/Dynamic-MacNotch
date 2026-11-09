import SwiftUI

/// Claude Code · Codex 작업 완료 알림. '연결'을 눌러야만 각 설정 파일에 훅을 넣는다.
struct AgentSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared
    private let refresh = State(initialValue: 0)
    private let errorState = State(initialValue: String?.none)

    var body: some View {
        let _ = refresh.wrappedValue   // 연결·해제 뒤 상태를 다시 읽는다
        Form {
            SettingsSection(SectionTitle.show) {
                Toggle(T("작업이 끝나면 알림 (누르면 그 앱 열기)", "Alert when a task finishes (click to open that app)"), isOn: $settings.agentAlerts)
            }
            SettingsSection(SectionTitle.style, footer: T("상세는 '에이전트 · 프로젝트'와 함께 끝난 작업(마지막으로 보낸 요청)을 한 줄로 보여 줍니다. 컴팩트는 아이콘과 '완료'만 보이고, 길게 누르면 상세로 볼 수 있습니다.",
                                                         "Detailed shows 'Agent · project' and the finished task (your last request) on one line. Compact shows only the icon and Done; long-press it to see the details."),
                            disabled: !settings.agentAlerts) {
                AlertStylePicker(selection: $settings.agentStyle)
            }
            SettingsSection(T("연결", "Connection"), footer: T("연결하면 Claude Code는 ~/.claude/settings.json에 '작업 완료(Stop)' 훅을, Codex는 ~/.codex/config.toml의 notify에 이 앱을 넣습니다. Codex에 이미 notify가 있으면 그 명령도 그대로 이어서 실행되고, 연결 해제 시 원래대로 돌려놓습니다. 처음 바꾸기 전 원본은 .dynamicmacnotch.bak으로 남깁니다. 새로 시작한 Claude Code·Codex 세션부터 적용됩니다.",
                                                           "Connecting adds a Stop hook to ~/.claude/settings.json for Claude Code, and sets notify in ~/.codex/config.toml for Codex. If Codex already has a notify command, it still runs, and disconnecting restores it. The original file is kept as .dynamicmacnotch.bak before the first change. Applies to new Claude Code and Codex sessions.")) {
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
        .settingsForm()
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
