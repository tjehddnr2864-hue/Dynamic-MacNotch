import SwiftUI

/// 디스플레이: 노치를 보일 디스플레이, 디스플레이별 상시 표시와 알림 범위.
/// 세부 항목은 디스플레이가 2개 이상 연결된 때만 보인다. 연결 상태가 바뀌면 목록이 바로 갱신된다.
struct DisplaysSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared
    private let listState = State(initialValue: Displays.all())

    private var list: [DisplayInfo] { listState.wrappedValue }

    private var enabled: [String] {
        Displays.enabledUUIDs(selection: settings.notchDisplays, content: settings.displayContent, connected: list.map(\.uuid))
    }

    var body: some View {
        Form {
            placementSection
            if list.count > 1 {
                contentSection
                alertSection
            }
        }
        .settingsForm()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            listState.wrappedValue = Displays.all()
        }
    }

    // MARK: 표시할 디스플레이

    /// 예전 값(builtIn·main)과 지금 연결되지 않은 디스플레이는 실제로 쓰이는 디스플레이로 보여 준다
    private var currentSelection: String {
        if settings.notchDisplays == "all" { return "all" }
        let screen = Displays.screen(for: settings.notchDisplays)
        return screen.flatMap(Displays.uuid(of:)).map(Displays.selection(uuid:)) ?? settings.notchDisplays
    }

    private var placementSection: some View {
        SettingsSection(SectionTitle.show, footer: list.count > 1 ? nil : T("디스플레이를 2개 이상 연결하면 고를 수 있습니다.", "Connect two or more displays to choose.")) {
            Picker(T("노치를 표시할 디스플레이", "Show the notch on"), selection: Binding(get: { currentSelection }, set: { settings.notchDisplays = $0 })) {
                ForEach(list) { Text($0.label).tag(Displays.selection(uuid: $0.uuid)) }
                if list.count > 1 {
                    Text(T("모든 디스플레이", "All Displays")).tag("all")
                }
            }
            .disabled(list.count < 2)
        }
    }

    // MARK: 상시 표시

    private var contentSection: some View {
        SettingsSection(T("디스플레이별 상시 표시", "Live Activity by Display"),
                        footer: T("선택한 항목이 비활성일 때 대신 표시하지 않으면 기본 노치만 뜹니다. '노치 없음'인 디스플레이에는 알림과 상호작용을 포함해 아무것도 뜨지 않습니다. 노치를 표시하지 않는 디스플레이는 고를 수 없습니다.",
                                  "If nothing replaces an inactive item, only the plain notch appears. A display set to No Notch shows nothing at all, including alerts and interactions. Displays that don't show the notch can't be changed.")) {
            ForEach(list) { row($0) }
            Toggle(T("선택한 항목이 비활성이면 주 디스플레이의 상시 표시를 대신 표시", "Show the main display's Live Activity when the selected item is inactive"),
                   isOn: $settings.displayFallbackToMain)
        }
    }

    /// 이 디스플레이가 '노치를 표시할 디스플레이'로 선택되어 있는지
    private func isSelected(_ uuid: String) -> Bool {
        settings.notchDisplays == "all" || Displays.screen(for: settings.notchDisplays).flatMap(Displays.uuid(of:)) == uuid
    }

    private func row(_ display: DisplayInfo) -> some View {
        let uuid = display.uuid
        let isLastNotch = enabled == [uuid]
        return Picker(display.name + (display.isMain ? T(" (주 디스플레이)", " (Main)") : ""),
                      selection: Binding(
                        get: { settings.displayContent[uuid] ?? (display.isMain ? DisplayChoice.all : DisplayChoice.followMain) },
                        set: { value in
                            guard value != DisplayChoice.none || !isLastNotch else { return }
                            settings.displayContent[uuid] = value
                        })) {
            Text(T("모든 상시 표시", "All Live Activities")).tag(DisplayChoice.all)
            Divider()
            ForEach(settings.persistentOrder, id: \.self) { key in
                let off = ActivityKind(rawValue: key)?.liveDisabled(in: settings) ?? false
                Text(ActivityKind.liveName(key) + (off ? T(" (설정에서 꺼짐)", " (Off in Settings)") : "")).tag(DisplayChoice.kind(key))
            }
            Divider()
            Text(T("노치만", "Notch Only")).tag(DisplayChoice.notchOnly)
            Text(isLastNotch ? T("노치 없음 (마지막 노치는 끌 수 없음)", "No Notch (the last notch stays on)") : T("노치 없음", "No Notch"))
                .tag(DisplayChoice.none)
                .disabled(isLastNotch)
            if !display.isMain {
                Text(T("주 디스플레이와 같게", "Same as Main Display")).tag(DisplayChoice.followMain)
            }
        }
        .disabled(!isSelected(uuid))
    }

    // MARK: 알림

    private var alertSection: some View {
        SettingsSection(T("디스플레이별 알림", "Alerts by Display"),
                        footer: T("중요한 알림은 일회성 알림 범위와 상시 표시 선택보다 우선합니다. '노치 없음'인 디스플레이에는 뜨지 않습니다.",
                                  "Important alerts take priority over the alert range and Live Activity choice, but never appear on a display set to No Notch.")) {
            MenuChoice(T("일회성 알림 범위", "Show alerts on"), selection: $settings.alertScope)
            Toggle(T("중요한 알림은 노치를 켠 모든 디스플레이에 표시", "Show important alerts on all displays with a notch"), isOn: $settings.criticalAlertsEnabled)
            DisclosureGroup(T("중요한 알림 항목", "Important Alerts")) {
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
        }
    }

    /// 기본 목록과의 차이만 저장한다: 나중에 기본 구성이 바뀌어도 직접 바꾼 것만 유지된다
    private func criticalBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { settings.criticalAlerts.contains(id) }, set: { on in
            let isDefault = CriticalAlert.defaults.contains(id)
            settings.criticalAlertAdded = settings.criticalAlertAdded.filter { $0 != id } + (on && !isDefault ? [id] : [])
            settings.criticalAlertRemoved = settings.criticalAlertRemoved.filter { $0 != id } + (!on && isDefault ? [id] : [])
        })
    }
}
