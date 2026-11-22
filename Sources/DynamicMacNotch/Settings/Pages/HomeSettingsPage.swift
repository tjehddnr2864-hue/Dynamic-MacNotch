import SwiftUI

/// 홈 기능: 길게 눌러 여는 홈의 페이지 순서와 켜기·끄기
struct HomeSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SettingsSection(T("홈 페이지 (노치를 길게 눌러 열기)", "Home Pages (long-press the notch)"),
                            footer: T("위에서부터 홈 페이지 순서입니다. 끈 기능은 노치에서 사라지고 백그라운드에서도 동작하지 않습니다. 에어드랍·트레이의 '홈에서 가림'은 페이지만 숨기고 파일을 노치로 끌어오면 그대로 동작하며, '끄기'는 파일을 끌어와도 동작하지 않습니다.",
                                      "Top to bottom is the Home page order. A feature that's off disappears from the notch and stops running in the background. For AirDrop & Tray, Hide in Home only removes the page, so dragging files to the notch still works, while Off ignores dragged files too.")) {
                ReorderList(items: settings.homeOrder, onCommit: { settings.homeOrder = $0 }) { key, index in
                    if let option = HomeOption(key: key) { row(option, index: index) }
                }
            }
            SettingsSection(T("카메라", "Camera"), disabled: !settings.isHomeFeatureOn("camera")) {
                Toggle(T("좌우 반전(거울)", "Mirror the camera"), isOn: $settings.cameraMirror)
                Picker(T("카메라", "Camera"), selection: $settings.cameraDevice) {
                    Text(T("시스템 기본", "System default")).tag("")
                    let cameras = Cameras.all()
                    ForEach(cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    // 고른 카메라가 지금 연결돼 있지 않으면 이름 대신 표시 (노치에서는 기본 카메라를 쓴다)
                    if !settings.cameraDevice.isEmpty, !cameras.contains(where: { $0.uniqueID == settings.cameraDevice }) {
                        Text(T("연결 안 된 카메라", "Camera not connected")).tag(settings.cameraDevice)
                    }
                }
            }
        }
        .settingsForm()
    }

    @ViewBuilder
    private func row(_ option: HomeOption, index: Int) -> some View {
        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
        Label(option.title, systemImage: option.symbol)
            .foregroundStyle(settings.isHomeFeatureOn(option.key) ? .primary : .secondary)
        Spacer()
        if option == .tray {
            Picker("", selection: $settings.trayMode) {
                ForEach(TrayMode.allCases) { Text($0.label).tag($0) }
            }
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
