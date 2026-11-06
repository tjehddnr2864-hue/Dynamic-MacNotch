import SwiftUI

/// AI 사용량: Claude · ChatGPT · Gemini 웹사이트에 로그인해 읽는다
struct UsageSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    private var isOn: Bool { settings.isHomeFeatureOn("usage") }

    var body: some View {
        let connected = AIService.connected(settings.aiConnected)
        Form {
            SettingsSection(SectionTitle.show) {
                HomePageToggle(settings: settings, key: "usage", title: T("홈에 AI 사용량 페이지 표시", "Show AI Usage in Home"))
            }
            SettingsSection(SectionTitle.live, footer: T("상시 표시를 끄면 백그라운드에서 새로고침하지 않고, 노치를 길게 눌러 AI 사용량 페이지를 열 때만 새로고침합니다. 두 손가락으로 잠시 가려 둔 동안에는 계속 새로고침하고, 우선순위가 더 높은 상시 항목에 가려진 동안에는 쉬었다가 다시 보이면 이어서 합니다.",
                                                        "When this is off, nothing refreshes in the background; usage refreshes only when you open the AI Usage page. While hidden with a two-finger swipe it keeps refreshing; while covered by a higher-priority item it pauses and resumes once visible again."),
                            disabled: !isOn) {
                Toggle(T("왼쪽 5시간 · 오른쪽 주간 한도 (한도가 하나면 오른쪽은 초기화까지 남은 시간)", "Left: 5-hour, right: weekly (with a single limit, the right shows time to reset)"), isOn: $settings.aiUsagePinned)
                Indented(enabled: settings.aiUsagePinned) {
                    Picker(T("표시할 서비스", "Service to show"), selection: $settings.aiUsageService) {
                        ForEach(AIService.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                }
            }
            SettingsSection(SectionTitle.style, disabled: !isOn) {
                SegmentedChoice(T("사용량 표시", "Usage display"), selection: $settings.aiUsageStyle)
            }
            SettingsSection(SectionTitle.details, footer: T("각 서비스 웹사이트에 로그인해 연동합니다. 로그인 정보는 이 앱 전용 웹 저장소에만 남으며, 사용량은 Claude(claude.ai 사용량), ChatGPT(Codex 사용 한도), Gemini(gemini.google.com/usage)에서 읽습니다.",
                                                           "Sign in on each service's website. Sign-in data stays in this app's own web storage. Usage is read from Claude (claude.ai usage), ChatGPT (Codex usage limits) and Gemini (gemini.google.com/usage)."),
                            disabled: !isOn) {
                ValueMenu(title: T("새로고침 빈도", "Refresh every"), selection: $settings.aiRefreshMinutes, values: [1, 2, 5, 10]) {
                    T("\(Int($0))분", "\(Int($0)) min")
                }
                ForEach(AIService.allCases) { service in
                    LabeledContent {
                        HStack(spacing: 8) {
                            StatusText(text: connected.contains(service) ? T("연결됨", "Connected") : T("연결 안 됨", "Not connected"), good: connected.contains(service))
                            if connected.contains(service) {
                                Button(T("로그아웃", "Sign Out")) { signOut(service) }
                            } else {
                                Button(T("로그인…", "Sign In…")) { UsageLoginWindow.show(service) }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(service.tint).frame(width: 8, height: 8)
                            Text(service.name)
                        }
                    }
                }
            }
            PreviewSection([(.aiUsage, T("상시 표시", "Live Activity"))])
        }
        .settingsForm()
    }

    private func signOut(_ service: AIService) {
        UsageWeb.signOut(service) {}
        settings.aiConnected = AppSettings.list(settings.aiConnected).filter { $0 != service.rawValue }.joined(separator: ",")
    }
}

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
