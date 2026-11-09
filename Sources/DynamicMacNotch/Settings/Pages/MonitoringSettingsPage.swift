import SwiftUI

/// 실시간 모니터링: AI 사용량(웹 로그인으로 읽음)과 자원 사용량(이 Mac에서 읽음).
/// 두 기능은 홈 기능에서 따로 켜고 끈다. 규칙은 docs/RESOURCE_GUIDELINE.md §3.
struct MonitoringSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let aiOn = settings.monitorAIOn, resourceOn = settings.monitorResourceOn
        let content = settings.effectiveMonitorContent
        let slots = settings.monitorSlots
        let hasAISlot = content == .ai || [slots?.left, slots?.right].contains { $0?.isAI == true }
        Form {
            SettingsSection(SectionTitle.show, footer: T("홈 기능의 스위치와 같은 설정입니다. 끄면 그 기능은 노치에서 사라지고 백그라운드에서도 멈춥니다.",
                                                        "Same as the switches in Home Features. A feature that's off disappears from the notch and stops running in the background.")) {
                HomePageToggle(settings: settings, key: "usage", title: T("AI 사용량", "AI Usage"))
                HomePageToggle(settings: settings, key: "resource", title: T("자원 사용량 (CPU · GPU · 메모리 · 네트워크)", "Resource Usage (CPU, GPU, Memory, Network)"))
            }
            SettingsSection(SectionTitle.live, footer: liveFooter(aiOn: aiOn, resourceOn: resourceOn), disabled: content == nil) {
                Toggle(T("노치에 상시 표시", "Show in the notch"), isOn: $settings.aiUsagePinned)
                Group {
                    contentPicker(aiOn: aiOn, resourceOn: resourceOn, content: content)
                    if let content, content != .ai, let slots {
                        slotPicker(T("왼쪽", "Left"), left: true, slots: slots, content: content)
                        slotPicker(T("오른쪽", "Right"), left: false, slots: slots, content: content)
                    }
                    if hasAISlot {
                        Picker(T("AI 서비스", "AI service"), selection: $settings.aiUsageService) {
                            ForEach(AIService.allCases) { Text($0.name).tag($0.rawValue) }
                        }
                    }
                }
                .disabled(!settings.aiUsagePinned)
            }
            SettingsSection(SectionTitle.style, disabled: content == nil) {
                SegmentedChoice(T("표시 형태", "Style"), selection: $settings.aiUsageStyle)
                expandPicker(aiOn: aiOn, resourceOn: resourceOn)
            }
            SettingsSection(SectionTitle.details, footer: T("AI 사용량은 각 서비스 웹사이트에 로그인해 읽습니다. 로그인 정보는 이 앱 전용 웹 저장소에만 남습니다. 상시 표시를 끄면 백그라운드에서 새로고침하지 않고, 홈의 AI 사용량 페이지를 열 때만 새로고침합니다. 자원 사용량은 노치에 보이는 동안만 읽습니다.",
                                                           "AI usage is read by signing in to each service's website. Sign-in data stays in this app's own web storage. With the Live Activity off, AI usage refreshes only when you open its Home page. Resource usage is read only while it's visible in the notch.")) {
                ValueMenu(title: T("AI 사용량 새로고침", "Refresh AI usage every"), selection: $settings.aiRefreshMinutes, values: [1, 2, 5, 10]) {
                    T("\(Int($0))분", "\(Int($0)) min")
                }
                .disabled(!aiOn)
                ValueMenu(title: T("자원 사용량 새로고침", "Refresh resource usage every"), selection: $settings.resourceRefreshSeconds, values: [1, 2, 5, 10]) {
                    T("\(Int($0))초", "\(Int($0)) s")
                }
                .disabled(!resourceOn)
                accounts.disabled(!aiOn)
            }
            PreviewSection([(.aiUsage, T("AI 사용량", "AI Usage"))])
        }
        .settingsForm()
    }

    // MARK: 상시 표시

    private func liveFooter(aiOn: Bool, resourceOn: Bool) -> String {
        var lines = [T("AI 사용량은 왼쪽에 5시간, 오른쪽에 주간 한도를 보입니다. 한도가 하나뿐인 요금제는 왼쪽에 서비스 기호, 오른쪽에 그 한도를 보입니다. 자원 사용량은 이 Mac 안에서만 읽고 어디로도 보내지 않습니다.",
                       "AI usage shows the 5-hour limit on the left and the weekly limit on the right. Plans with a single limit show the service mark on the left and that limit on the right. Resource usage is read on this Mac and never sent anywhere.")]
        switch (aiOn, resourceOn) {
        case (true, false): lines.append(T("자원 사용량은 홈 기능에서 꺼져 있습니다.", "Resource Usage is off in Home Features."))
        case (false, true): lines.append(T("AI 사용량은 홈 기능에서 꺼져 있습니다.", "AI Usage is off in Home Features."))
        case (false, false): lines.append(T("두 기능이 모두 홈 기능에서 꺼져 있습니다.", "Both features are off in Home Features."))
        default: break
        }
        return lines.joined(separator: " ")
    }

    /// 켜진 기능만 고를 수 있다. 하나만 켜져 있으면 그 하나를 보여 준다.
    @ViewBuilder
    private func contentPicker(aiOn: Bool, resourceOn: Bool, content: MonitorContent?) -> some View {
        let available = MonitorLayout.availableContents(aiOn: aiOn, resourceOn: resourceOn)
        if available.count > 1 {
            Picker(T("표시할 항목", "Show"), selection: Binding(get: { content ?? .ai }, set: { settings.monitorContent = $0 })) {
                ForEach(available) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        } else {
            LabeledContent(T("표시할 항목", "Show")) {
                Text(content?.label ?? "–").foregroundStyle(.secondary)
            }
        }
    }

    /// 칸 하나. 반대편에서 고른 항목은 고를 수 없다.
    private func slotPicker(_ title: String, left: Bool, slots: (left: MonitorMetric, right: MonitorMetric), content: MonitorContent) -> some View {
        let other = left ? slots.right : slots.left
        return Picker(title, selection: Binding(get: { left ? slots.left : slots.right },
                                                set: { settings.setMonitorSlot($0, left: left) })) {
            ForEach(MonitorLayout.choices(for: content)) { metric in
                Text(metric.label).tag(metric).disabled(metric == other)
            }
        }
    }

    // MARK: 표시 방식

    @ViewBuilder
    private func expandPicker(aiOn: Bool, resourceOn: Bool) -> some View {
        let options = MonitorLayout.availableExpands(aiOn: aiOn, resourceOn: resourceOn)
        if !options.isEmpty {
        Picker(T("꾹 눌렀을 때 보일 내용", "On long-press, show"),
               selection: Binding(get: { options.contains(settings.monitorExpand) ? settings.monitorExpand : .follow },
                                  set: { settings.monitorExpand = $0 })) {
            ForEach(options) { Text($0.label).tag($0) }
        }
        }
    }

    // MARK: 로그인

    private var accounts: some View {
        let connected = AIService.connected(settings.aiConnected)
        return ForEach(AIService.allCases) { service in
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

    private func signOut(_ service: AIService) {
        UsageWeb.signOut(service) {}
        settings.aiConnected = AppSettings.list(settings.aiConnected).filter { $0 != service.rawValue }.joined(separator: ",")
    }
}
