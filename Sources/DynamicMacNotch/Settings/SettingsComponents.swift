import SwiftUI

// 모든 설정 페이지가 함께 쓰는 부품. 규칙과 용어는 docs/ARCHITECTURE.md의 "설정 화면 규칙"에 있다.
//
// 고르는 방법
// - 종류를 고르는 2~3개 선택지: SegmentedChoice
// - 그보다 많거나 글이 긴 선택지: MenuChoice
// - 시간·개수 같은 정해진 값 목록: ValueMenu
// - 연속된 값: ValueSlider
// - 켜고 끄기: Toggle

extension View {
    /// 유리 배경이 비치도록 폼 자체 배경을 지운다.
    func settingsForm() -> some View {
        formStyle(.grouped).scrollContentBackground(.hidden)
    }
}

/// 구역 아래의 설명. 구역 제목과 같은 왼쪽 줄에 맞춘다.
func footnote(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
}

/// 기능별 페이지의 구역 이름. 순서: 표시 → 상시 표시 → 표시 방식 → 세부 설정 → 미리보기.
enum SectionTitle {
    static var show: String { T("표시", "Show") }
    static var live: String { T("상시 표시", "Live Activity") }
    static var style: String { T("표시 방식", "Appearance") }
    static var details: String { T("세부 설정", "Details") }
    static var preview: String { T("미리보기", "Preview") }
}

/// 제목, 설명, 비활성 조건이 있는 구역
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    var disabled: Bool
    private let content: Content

    init(_ title: String? = nil, footer: String? = nil, disabled: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.disabled = disabled
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            if let title { Text(title) }
        } footer: {
            if let footer { footnote(footer) }
        }
        .disabled(disabled)
    }
}

/// 위 항목에 딸린 항목. 들여 쓰고, 위 항목이 꺼져 있으면 비활성.
struct Indented<Content: View>: View {
    var enabled: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content.padding(.leading, 16).disabled(!enabled)
    }
}

// MARK: - 고르기

/// 설정 화면에 이름을 보여 줄 수 있는 선택지
protocol SettingOption: CaseIterable, Identifiable, Hashable where AllCases: RandomAccessCollection {
    var label: String { get }
}

extension HapticStrength: SettingOption {}
extension AlertStyle: SettingOption {}
extension BatteryDisplay: SettingOption {}
extension HUDStyle: SettingOption {}
extension ProgressStyle: SettingOption {}
extension ScreenshotSource: SettingOption {}
extension RecordingStyle: SettingOption {}
extension TrayMode: SettingOption {}
extension FileDragPage: SettingOption {}
extension AlertScope: SettingOption {}
extension ChatReopen: SettingOption {}
extension UsageStyle: SettingOption {}
extension MediaSource: SettingOption {}
extension AppLanguage: SettingOption {}

struct SegmentedChoice<Option: SettingOption>: View {
    var title: String
    @Binding var selection: Option

    init(_ title: String, selection: Binding<Option>) {
        self.title = title
        _selection = selection
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Option.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

struct MenuChoice<Option: SettingOption>: View {
    var title: String
    @Binding var selection: Option

    init(_ title: String, selection: Binding<Option>) {
        self.title = title
        _selection = selection
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Option.allCases) { Text($0.label).tag($0) }
        }
    }
}

/// 정해진 값 목록에서 고르기. `zero`가 있으면 맨 위에 0 값의 선택지를 둔다 (끄기, 일반 설정 따름 등).
struct ValueMenu: View {
    var title: String
    @Binding var selection: Double
    var values: [Double]
    var zero: String? = nil
    var label: (Double) -> String

    var body: some View {
        Picker(title, selection: $selection) {
            if let zero { Text(zero).tag(0.0) }
            ForEach(values, id: \.self) { Text(label($0)).tag($0) }
        }
    }
}

/// 값이 오른쪽에 보이는 슬라이더
struct ValueSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(format(value)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }
}

/// 일회성 알림의 형태
struct AlertStylePicker: View {
    @Binding var selection: AlertStyle

    var body: some View {
        SegmentedChoice(T("표시 형태", "Style"), selection: $selection)
    }
}

/// 알림의 표시 시간. 0이면 일반 설정을 따른다.
struct AlertDurationMenu: View {
    @Binding var selection: Double

    var body: some View {
        ValueMenu(title: T("표시 시간", "Duration"), selection: $selection, values: [1.5, 2.5, 4.0, 6.0],
                  zero: T("일반 설정 따름", "Same as General")) { L10n.seconds($0, digits: 1) }
    }
}

/// 진행률의 형태
struct ProgressStylePicker: View {
    @Binding var selection: ProgressStyle

    var body: some View {
        SegmentedChoice(T("진행률 표시", "Progress"), selection: $selection)
    }
}

/// 쉼표로 나눠 적는 목록. 비어 있어도 입력 칸인 줄 알 수 있게 테두리와 안내 글을 둔다.
struct ListField: View {
    var title: String
    @Binding var text: String

    var body: some View {
        LabeledContent(title) {
            TextField("", text: $text, prompt: Text(T("쉼표로 구분", "Comma-separated")))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .labelsHidden()
        }
    }
}

/// 설정 → 기능 페이지의 '홈에 이 페이지 표시' 스위치 (홈 기능 페이지의 스위치와 같은 값)
struct HomePageToggle: View {
    @ObservedObject var settings: AppSettings
    var key: String
    var title: String? = nil

    var body: some View {
        Toggle(title ?? T("홈에 페이지 표시", "Show page in Home"),
               isOn: Binding(get: { settings.isHomeFeatureOn(key) }, set: { settings.setHomeFeature(key, on: $0) }))
    }
}

// MARK: - 상태 · 폴더

/// 연결됨·저장됨처럼 좋은 상태면 초록, 아니면 회색인 글
struct StatusText: View {
    var text: String
    var good: Bool

    var body: some View {
        Text(text).foregroundStyle(good ? .green : .secondary)
    }
}

/// 폴더 경로 설정: 현재 경로, '선택…'(폴더 고르기), '기본값'.
struct FolderSetting: View {
    var title: String
    @Binding var path: String
    var defaultPath: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text((path.isEmpty ? defaultPath : path).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 220, alignment: .trailing)
                Button(T("선택…", "Choose…")) { choose() }
                if !path.isEmpty, path != defaultPath {
                    Button(T("기본값", "Default")) { path = defaultPath }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path.isEmpty ? defaultPath : path)
        panel.prompt = T("선택", "Choose")
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

// MARK: - 미리보기

extension PreviewID {
    /// 본 앱의 노치에 이 미리보기를 띄운다 (설정 창은 별도 프로세스). `style`을 주면 그 형태로.
    func run(style: AlertStyle? = nil) {
        Helper.sendToMain("preview:" + rawValue + (style.map { "@" + $0.rawValue } ?? ""))
    }
}

/// 기능별 페이지 맨 아래의 미리보기 버튼 줄. 현재 설정 그대로 보여 준다.
struct PreviewSection: View {
    var items: [(id: PreviewID, label: String)]

    init(_ items: [(id: PreviewID, label: String)]) {
        self.items = items
    }

    var body: some View {
        Section(SectionTitle.preview) {
            HStack(spacing: 8) {
                ForEach(items, id: \.id) { item in
                    Button(item.label) { item.id.run() }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
