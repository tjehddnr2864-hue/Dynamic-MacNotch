import SwiftUI

/// 일반: 앱 전체에 적용되는 설정과 노치 조작 (기능별 설정은 상호작용 아래에 둔다)
struct GeneralSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    /// 이 설정 창이 열릴 때의 언어 (바뀌었는지 비교용)
    private static let launchLanguage = AppSettings.shared.language

    var body: some View {
        Form {
            SettingsSection(T("앱", "App"), footer: T("메모리가 최적화 기준을 넘으면 쉬는 동안 조용히 다시 시작합니다.", "Above the cleanup limit, the app quietly restarts while idle.")) {
                MenuChoice(T("언어", "Language"), selection: $settings.language)
                if settings.language != Self.launchLanguage {
                    HStack {
                        footnote(T("다시 시작하면 적용됩니다.", "Applies after restarting the app."))
                        Spacer()
                        Button(T("지금 다시 시작", "Restart Now")) {
                            Helper.sendToMain("restart")
                            NSApp.terminate(nil)   // 설정 창(도우미)도 닫는다
                        }
                    }
                }
                Toggle(T("메뉴바 아이콘 표시", "Show menu bar icon"), isOn: $settings.showStatusItem)
                Toggle(T("자동 업데이트 (하루 한 번 확인)", "Automatic updates (checks daily)"), isOn: $settings.autoUpdate)
                Toggle(T("메모리 자동 최적화", "Automatic memory cleanup"), isOn: $settings.memoryGuard)
                Indented(enabled: settings.memoryGuard) {
                    ValueMenu(title: T("최적화 기준", "Cleanup limit"), selection: $settings.memoryLimitMB,
                              values: [70, 80, 90, 100, 110, 120, 130, 140, 150]) { "\(Int($0)) MB" }
                }
            }
            SettingsSection(T("노치 조작", "Notch Controls"), footer: T("마우스는 압력을 알려 주지 않아 길게 누르기만 동작합니다.", "Mice don't report pressure, so only long-press works with a mouse.")) {
                ValueSlider(title: T("길게 누르기 시간", "Long-press duration"), value: $settings.longPressDuration, range: 0.2...0.8, step: 0.05) {
                    L10n.seconds($0, digits: 2)
                }
                Toggle(T("깊게 누르기(포스 터치)로 바로 열기", "Open with Force Click"), isOn: $settings.forceTouchEnabled)
                SegmentedChoice(T("햅틱 강도", "Haptic strength"), selection: $settings.hapticStrength)
                Toggle(T("호버하면 살짝 커지기", "Grow slightly on hover"), isOn: $settings.hoverPreview)
                Toggle(T("호버만으로 열기", "Open on hover"), isOn: $settings.hoverToOpen)
            }
            SettingsSection(T("일회성 알림", "Alerts"), footer: T("기능별 페이지에서 표시 시간을 '일반 설정 따름'으로 둔 알림에 적용됩니다.", "Applies to alerts whose Duration is Same as General on their feature page.")) {
                ValueMenu(title: T("기본 표시 시간", "Default duration"), selection: $settings.transientDuration, values: [1.5, 2.5, 4.0, 6.0]) {
                    L10n.seconds($0, digits: 1)
                }
            }
            SettingsSection(T("설정 창 모양", "Settings Window"), footer: T("흐림을 낮추면 뒤 화면이 또렷하게, 투명도를 높이면 더 많이 비쳐 보입니다.", "Lower blur shows the screen behind more sharply; higher transparency lets more of it through.")) {
                ValueSlider(title: T("배경 흐림", "Background blur"), value: $settings.settingsBlur, range: 0...1, step: 0.05, format: Self.percent)
                ValueSlider(title: T("투명도", "Transparency"), value: $settings.settingsTransparency, range: 0...0.9, step: 0.05, format: Self.percent)
            }
        }
        .settingsForm()
    }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// 정보
struct AboutSettingsPage: View {
    private static let repository = "github.com/tjehddnr2864-hue/Dynamic-MacNotch"

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Dynamic MacNotch").font(.title.bold())
            Text(T("버전 ", "Version ") + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")).foregroundStyle(.secondary)
            footnote(T("Apple Silicon(M1 이상) · macOS 14 Sonoma 이상", "Apple Silicon (M1 or later) · macOS 14 Sonoma or later"))
            Link(Self.repository, destination: URL(string: "https://" + Self.repository)!)
                .font(.caption)
            Text(T("애드혹 서명(공증되지 않음)", "Ad-hoc signed (not notarized)")).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}
