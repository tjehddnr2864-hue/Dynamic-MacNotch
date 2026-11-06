import SwiftUI

/// 설정 → 상호작용 → 기본 → 디스플레이. 디스플레이가 2개 이상 연결된 때만 보인다.
struct DisplaySettingsSection: View {
    @ObservedObject var settings: AppSettings
    private let listState = State(initialValue: Displays.all())

    private var connected: [String] { listState.wrappedValue.map(\.uuid) }

    private var enabled: [String] {
        Displays.enabledUUIDs(selection: settings.notchDisplays, content: settings.displayContent, connected: connected)
    }

    /// 이 디스플레이가 "표시 화면"으로 선택되어 있는지
    private func isSelected(_ uuid: String) -> Bool {
        if settings.notchDisplays == "all" { return true }
        return Displays.screen(for: settings.notchDisplays).flatMap(Displays.uuid(of:)) == uuid
    }

    var body: some View {
        Group {
            if listState.wrappedValue.count > 1 {
                contentSection
                alertSection
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            listState.wrappedValue = Displays.all()
        }
    }

    // MARK: 상시 표시

    private var contentSection: some View {
        Section {
            ForEach(listState.wrappedValue) { display in
                row(display)
            }
            Toggle(T("선택한 상시 표시가 비활성화인 경우 주 디스플레이의 상시 표시 컨텐츠를 표시",
                     "Show the main display's live activity when the selected one is inactive"), isOn: $settings.displayFallbackToMain)
        } header: {
            Text(T("디스플레이별 상시 표시", "Live Activity by Display"))
        } footer: {
            footnote(T("이 옵션을 끄면 선택한 상시 표시가 비활성화인 경우 기본 노치만 뜹니다. '노치 없음'인 디스플레이에는 알림과 상호작용을 포함해 아무것도 뜨지 않습니다. 디스플레이를 함께 쓰려면 일반의 표시 화면에서 '모든 디스플레이'를 고르세요.",
                       "With this off, only the plain notch appears when the selected activity is inactive. A display set to No Notch shows nothing at all, including alerts and interactions. To use several displays, choose All Displays under Display in General."))
        }
    }

    private func row(_ display: DisplayInfo) -> some View {
        let uuid = display.uuid
        let isOnlyOne = enabled == [uuid]
        return Picker(display.name + (display.isMain ? T(" (주 디스플레이)", " (Main)") : ""),
                      selection: Binding(
                        get: { settings.displayContent[uuid] ?? (display.isMain ? DisplayChoice.all : DisplayChoice.followMain) },
                        set: { value in
                            guard value != DisplayChoice.none || !isOnlyOne else { return }
                            var content = settings.displayContent
                            content[uuid] = value
                            settings.displayContent = content
                        })) {
            Text(T("모든 상시 표시 컨텐츠", "All Live Activities")).tag(DisplayChoice.all)
            Divider()
            ForEach(settings.persistentOrder, id: \.self) { key in
                Text(SettingsView.persistentName(key) + (isOff(key) ? T(" (설정에서 꺼짐)", " (Off in Settings)") : "")).tag(DisplayChoice.kind(key))
            }
            Divider()
            Text(T("노치만", "Notch Only")).tag(DisplayChoice.notchOnly)
            Text(isOnlyOne ? T("노치 없음 (마지막 노치는 끌 수 없음)", "No Notch (the last notch stays on)") : T("노치 없음", "No Notch"))
                .tag(DisplayChoice.none)
                .disabled(isOnlyOne)
            if !display.isMain {
                Text(T("주 디스플레이의 설정을 따름", "Same as Main Display")).tag(DisplayChoice.followMain)
            }
        }
        .disabled(!isSelected(uuid))
    }

    /// 그 기능의 상시 표시 설정이 꺼져 있어 항상 비활성인 항목
    private func isOff(_ key: String) -> Bool {
        switch key {
        case "vpn": return !settings.vpnPinned
        case "hotspot": return !settings.hotspotPinned
        case "focusPinned": return !settings.focusPinned
        case "aiUsage": return !settings.aiUsagePinned
        case "battery": return !settings.batteryChargingPinned
        case "calendar": return !settings.calendarPinned
        default: return false
        }
    }

    // MARK: 알림

    private var alertSection: some View {
        Section {
            Picker(T("일회성 알림 표시", "Show Alerts On"), selection: $settings.alertScope) {
                Text(T("주 디스플레이만", "Main Display Only")).tag("main")
                Text(T("노치를 켠 모든 디스플레이", "All Displays with a Notch")).tag("all")
            }
            Toggle(T("중요한 알림은 노치를 켠 모든 디스플레이에 표시", "Show important alerts on all displays with a notch"), isOn: $settings.criticalAlertsEnabled)
            DisclosureGroup(T("표시할 알림", "Important Alerts")) {
                ForEach(CriticalAlert.all, id: \.self) { id in
                    Toggle(CriticalAlert.label(id), isOn: criticalBinding(id))
                }
                Button(T("기본값으로 되돌리기", "Restore Defaults")) {
                    settings.criticalAlertAdded = []
                    settings.criticalAlertRemoved = []
                }
                .disabled(settings.criticalAlertAdded.isEmpty && settings.criticalAlertRemoved.isEmpty)
            }
            .disabled(!settings.criticalAlertsEnabled)
        } header: {
            Text(T("디스플레이별 알림", "Alerts by Display"))
        } footer: {
            footnote(T("중요한 알림은 알림 범위와 상시 표시 선택보다 우선합니다. '노치 없음'인 디스플레이에는 뜨지 않습니다.",
                       "Important alerts take priority over the alert range and live activity choice, but never appear on a display set to No Notch."))
        }
    }

    /// 기본 목록과의 차이만 저장한다: 나중에 기본 구성이 바뀌어도 직접 바꾼 것만 유지된다
    private func criticalBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { settings.criticalAlerts.contains(id) }, set: { on in
            var added = settings.criticalAlertAdded.filter { $0 != id }
            var removed = settings.criticalAlertRemoved.filter { $0 != id }
            let isDefault = CriticalAlert.defaults.contains(id)
            if on, !isDefault { added.append(id) }
            if !on, isDefault { removed.append(id) }
            settings.criticalAlertAdded = added
            settings.criticalAlertRemoved = removed
        })
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
