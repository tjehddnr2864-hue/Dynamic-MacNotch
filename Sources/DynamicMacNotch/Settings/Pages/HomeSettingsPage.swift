import SwiftUI

/// 홈 기능: 길게 눌러 여는 홈의 페이지 순서와 켜기·끄기
struct HomeSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SettingsSection(T("홈 페이지", "Home Pages"),
                            footer: T("노치를 길게 누르면 열립니다. 끈 기능은 동작하지 않습니다.", "Long-press the notch to open Home. Features that are off don't run."), more: T("위에서부터 홈 페이지 순서입니다. 끈 기능은 노치에서 사라지고 백그라운드에서도 동작하지 않습니다. 에어드랍·트레이의 '홈에서 가림'은 페이지만 숨기고 파일을 노치로 끌어오면 그대로 동작하며, '끄기'는 파일을 끌어와도 동작하지 않습니다.",
                                      "Top to bottom is the Home page order. A feature that's off disappears from the notch and stops running in the background. For AirDrop & Tray, Hide in Home only removes the page, so dragging files to the notch still works, while Off ignores dragged files too.")) {
                ReorderList(items: settings.homeOrder, onCommit: { settings.homeOrder = $0 }) { key, index in
                    if let option = HomeOption(key: key) { row(option, index: index) }
                }
            }
            SettingsSection(T("카메라", "Camera"), disabled: !settings.isHomeFeatureOn("camera"), disabledNote: T("홈 페이지에서 카메라를 켜면 바꿀 수 있습니다.", "Turn on Camera in Home Pages to change this.")) {
                Toggle(T("좌우 반전", "Mirror"), detail: T("거울처럼 좌우를 바꿔 보입니다.", "Shows the camera like a mirror."), isOn: $settings.cameraMirror)
                ListChoice(T("카메라", "Camera"), selection: $settings.cameraDevice, items: cameraItems, style: .menu)
            }
        }
        .settingsForm()
    }

    /// 시스템 기본 + 연결된 카메라. 고른 카메라가 지금 없으면 그 자리를 남겨 표시한다 (노치에서는 기본 카메라를 쓴다)
    private var cameraItems: [(value: String, label: String)] {
        let cameras = Cameras.all()
        var items: [(value: String, label: String)] = [("", T("시스템 기본", "System default"))] + cameras.map { ($0.uniqueID, $0.localizedName) }
        if !settings.cameraDevice.isEmpty, !cameras.contains(where: { $0.uniqueID == settings.cameraDevice }) {
            items.append((settings.cameraDevice, T("연결 안 된 카메라", "Camera not connected")))
        }
        return items
    }

    @ViewBuilder
    private func row(_ option: HomeOption, index: Int) -> some View {
        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
        Label(option.title, systemImage: option.symbol)
            .foregroundStyle(settings.isHomeFeatureOn(option.key) ? .primary : .secondary)
        Spacer()
        if option == .tray {
            // 줄 안이라 이름은 숨기지만 VoiceOver는 읽는다 (인벤토리 §1-⑥)
            Choice(option.title, selection: $settings.trayMode, style: .menu)
                .labelsHidden()
                .fixedSize()
        } else {
            Toggle("", isOn: Binding(get: { settings.isHomeFeatureOn(option.key) }, set: { settings.setHomeFeature(option.key, on: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
