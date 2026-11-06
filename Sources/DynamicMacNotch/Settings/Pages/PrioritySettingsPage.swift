import SwiftUI

/// 우선순위: 여러 상시 표시 항목 중 무엇을 먼저 보일지
struct PrioritySettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SettingsSection(T("상시 표시 우선순위", "Live Activity Priority"),
                            footer: T("여러 항목이 동시에 진행 중이면 위에 있는 항목이 노치에 표시됩니다. 노치 위에서 두 손가락으로 위로 쓸면 숨기고, 아래로 쓸면 다시 나타납니다.",
                                      "When several activities run at once, the one higher in the list is shown. Swipe up with two fingers on the notch to hide them, and swipe down to show them again.")) {
                ReorderList(items: settings.persistentOrder, onCommit: { settings.persistentOrder = $0 }) { key, index in
                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
                    Label(ActivityKind.liveName(key), systemImage: ActivityKind.liveSymbol(key))
                    Spacer()
                }
            }
        }
        .settingsForm()
    }
}

/// 상호작용: 기능별 페이지로 가는 카드 모음
struct InteractionsOverview: View {
    var open: (SettingsPage) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(SettingsPage.features) { item in
                    Button { open(item) } label: {
                        VStack(spacing: 8) {
                            SettingsIcon(page: item, size: 22)
                                .foregroundStyle(Color.accentColor)
                                .frame(height: 28)
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            footnote(T("각 기능을 눌러 표시 여부, 표시 방식, 세부 설정을 바꾸고 바로 미리 볼 수 있습니다.",
                       "Choose a feature to change whether and how it appears, adjust its details and preview it."))
                .padding(.horizontal, 20)
        }
    }
}

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
