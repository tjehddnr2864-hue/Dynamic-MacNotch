import SwiftUI

// 모든 설정 페이지가 함께 쓰는 부품. 규칙과 용어는 docs/ARCHITECTURE.md의 "설정 화면 규칙"에 있다.
//
// 고르는 방법 (페이지에서는 이 부품만 쓴다. scripts/check-settings-ui.sh가 확인)
// - 켜고 끄기: Toggle. 위 항목에 딸린 항목은 Indented로 들여 쓴다
// - 종류 고르기: Choice (선택지 3개 이하면 분절 버튼, 4개 이상이면 메뉴. 글이 길면 style: .menu)
//   - 목록이 실행 중에 정해지는 것(기기·서비스·한도): ListChoice / 구분선·비활성 항목이 필요하면 ChoiceMenu
// - 시간·개수 같은 정해진 값: ValueMenu + Choices의 이름 붙은 목록 + Format
// - 연속된 값: ValueSlider + Format

extension View {
    /// 유리 배경이 비치도록 폼 자체 배경을 지운다.
    func settingsForm() -> some View {
        formStyle(.grouped).scrollContentBackground(.hidden)
    }
}

private struct SettingsPageKey: EnvironmentKey {
    static let defaultValue: SettingsPage? = nil
}

extension EnvironmentValues {
    /// 지금 보이는 설정 페이지 (머리 카드가 읽는다)
    var settingsPage: SettingsPage? {
        get { self[SettingsPageKey.self] }
        set { self[SettingsPageKey.self] = newValue }
    }
}

/// 설정 페이지의 폼: 맨 위에 머리 카드(같은 아이콘을 크게 + 제목 + 한 줄 설명)를 두고 함께 스크롤한다.
struct SettingsForm<Content: View>: View {
    @Environment(\.settingsPage) private var page
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            if let page {
                // 카드 배경 없는 줄로 둔다 (빈 구역의 머리글로 두면 다음 구역 제목이 작게 그려진다)
                Section { PageHeader(page: page).listRowBackground(Color.clear).listRowSeparator(.hidden) }
            }
            content
        }
        .settingsForm()
    }
}

/// 페이지 머리 카드. 아이콘은 사이드바와 같은 기호·강조색이며 크기만 크다 (타일 배경 없음).
struct PageHeader: View {
    var page: SettingsPage

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsIcon(page: page, size: 28)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title).font(.title.bold()).foregroundStyle(.primary)
                Text(page.summary).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .textCase(nil)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 구역 아래의 설명. 구역 제목과 같은 왼쪽 줄에 맞춘다. 11pt (macOS subheadline) — 설정 화면 글의 최소 크기.
func footnote(_ text: String) -> some View {
    Text(text).font(.subheadline).foregroundStyle(.secondary)
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

/// 제목, 설명, 비활성 조건이 있는 구역.
/// - `footer`: 한두 줄(60자 안팎) 요약. 더 긴 설명은 `more`에 두면 '자세히'를 눌러 펼친다.
/// - `disabledNote`: 구역이 비활성일 때 왜 그런지 (예: "다운로드 진행 표시를 켜면 바꿀 수 있습니다.")
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    var more: String?
    var disabled: Bool
    var disabledNote: String?
    private let content: Content
    private let expandedState = State(initialValue: false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String? = nil, footer: String? = nil, more: String? = nil, disabled: Bool = false, disabledNote: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.more = more
        self.disabled = disabled
        self.disabledNote = disabledNote
        self.content = content()
    }

    var body: some View {
        Section {
            content
                .disabled(disabled)
        } header: {
            if let title { Text(title) }
        } footer: {
            if (disabled && disabledNote != nil) || footer != nil || more != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if disabled, let disabledNote {
                        Label(disabledNote, systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if footer != nil || more != nil {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let footer { footnote(footer).fixedSize(horizontal: false, vertical: true) }
                            if more != nil {
                                Button(expandedState.wrappedValue ? T("접기", "Less") : T("자세히", "Details")) {
                                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expandedState.wrappedValue.toggle() }
                                }
                                .buttonStyle(.link)
                                .font(.subheadline)
                                .fixedSize()
                                if footer == nil { Spacer(minLength: 0) }
                            }
                        }
                        if expandedState.wrappedValue, let more { footnote(more) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 줄 이름 + 그 아래 작은 보조 설명 (한 문장, 60자 안팎). 설정 화면의 모든 줄이 이 모양을 쓴다.
struct RowLabel: View {
    var title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension Toggle where Label == RowLabel {
    /// 이름 + 보조 설명이 있는 스위치
    init(_ title: String, detail: String?, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { RowLabel(title: title, detail: detail) }
    }
}

/// 위 항목에 딸린 항목. 들여 쓰고, 위 항목이 꺼져 있으면 비활성.
/// grouped 폼은 스위치를 모두 작은 크기(mini)로 그린다 — 더 작게는 안 되고 `.large`만 커진다 (2026-11 실측).
/// 그래서 딸린 항목은 크기가 아니라 들여쓰기로 구분한다.
struct Indented<Content: View>: View {
    var enabled: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content.padding(.leading, 16).disabled(!enabled)
    }
}

// MARK: - 값 목록 · 표시 형식

/// 설정 화면의 정해진 값 목록. 같은 종류의 값은 어디서나 같은 목록을 쓴다.
/// 목록을 바꿀 때는 저장돼 있을 수 있는 예전 값을 빼지 않는다 (빠지면 메뉴가 빈칸으로 보인다).
enum Choices {
    /// 알림·HUD의 표시 시간(초). 예전 목록: HUD 1~4초, 알림 1.5~6초 → 둘을 합침
    static let duration: [Double] = [1.0, 1.5, 2.5, 4.0, 6.0]
    /// 메모리 자동 최적화 기준(MB)
    static let memoryLimit: [Double] = [70, 80, 90, 100, 110, 120, 130, 140, 150]
    /// 새로고침 간격 (AI 사용량은 분, 시스템 모니터링은 초)
    static let refresh: [Double] = [1, 2, 5, 10]
    /// 미디어 일시정지 후 숨김(초)
    static let mediaHide: [Double] = [10, 30, 60]
    /// 스크린샷 카드 자동 닫힘(초)
    static let screenshotClose: [Double] = [5, 10, 30]
    /// 일정 알림(분 전)
    static let calendarAlert: [Double] = [5, 10, 15]
    /// 트레이 자동 정리(분): 5분 ~ 1주
    static let trayCleanup: [Double] = [5, 10, 30, 60, 1440, 10080]
}

/// 값의 표시 형식. 페이지마다 따로 만들지 않는다.
enum Format {
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    static func seconds(_ value: Double) -> String { L10n.seconds(value, digits: value == value.rounded() ? 0 : (value * 10 == (value * 10).rounded() ? 1 : 2)) }
    static func seconds(_ value: Double, digits: Int) -> String { L10n.seconds(value, digits: digits) }
    static func minutes(_ value: Double) -> String { T("\(Int(value))분", "\(Int(value)) min") }
    static func megabytes(_ value: Double) -> String { "\(Int(value)) MB" }
    static func points(_ value: Double) -> String { "\(Int(value))pt" }
    /// 분 단위 기간: 60분 이상은 시간, 1440분 이상은 일
    static func period(minutes value: Double) -> String {
        let m = Int(value)
        if m >= 1440, m % 1440 == 0 { return T("\(m / 1440)일", m / 1440 == 1 ? "1 day" : "\(m / 1440) days") }
        if m >= 60, m % 60 == 0 { return T("\(m / 60)시간", m / 60 == 1 ? "1 hour" : "\(m / 60) hours") }
        return minutes(value)
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
extension BrightnessUnit: SettingOption {}
extension HUDDesign: SettingOption {}
extension LiquidHUDValue: SettingOption {}
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
extension MonitorContent: SettingOption {}
extension MonitorExpand: SettingOption {}
extension MonitorMetric: SettingOption {}

enum ChoiceStyle {
    /// 선택지 3개 이하면 분절 버튼, 4개 이상이면 메뉴
    case automatic
    /// 선택지 글이 길거나 줄 안에 좁게 들어갈 때
    case menu
}

private extension View {
    @ViewBuilder
    func choiceStyle(_ style: ChoiceStyle, count: Int) -> some View {
        if style == .automatic, count <= 3 { pickerStyle(.segmented) } else { pickerStyle(.menu) }
    }
}

/// 종류 고르기. `options`를 주면 그 선택지만 보인다 (지금 켜진 기능만 고를 때).
struct Choice<Option: SettingOption>: View {
    var title: String
    var detail: String?
    @Binding var selection: Option
    var options: [Option]?
    var style: ChoiceStyle

    init(_ title: String, detail: String? = nil, selection: Binding<Option>, options: [Option]? = nil, style: ChoiceStyle = .automatic) {
        self.title = title
        self.detail = detail
        _selection = selection
        self.options = options
        self.style = style
    }

    var body: some View {
        let items = options ?? Array(Option.allCases)
        Picker(selection: $selection) {
            ForEach(items) { Text($0.label).tag($0) }
        } label: { RowLabel(title: title, detail: detail) }
        .choiceStyle(style, count: items.count)
    }
}

/// 실행 중에 정해지는 목록에서 고르기 (기기, 서비스, 한도 등)
struct ListChoice<Value: Hashable>: View {
    var title: String
    var detail: String?
    @Binding var selection: Value
    var items: [(value: Value, label: String)]
    var style: ChoiceStyle = .automatic

    init(_ title: String, detail: String? = nil, selection: Binding<Value>, items: [(value: Value, label: String)], style: ChoiceStyle = .automatic) {
        self.title = title
        self.detail = detail
        _selection = selection
        self.items = items
        self.style = style
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(items.indices, id: \.self) { i in Text(items[i].label).tag(items[i].value) }
        } label: { RowLabel(title: title, detail: detail) }
        .choiceStyle(style, count: items.count)
    }
}

/// 구분선이나 고를 수 없는 항목이 섞인 메뉴 (디스플레이별 상시 표시처럼)
struct ChoiceMenu<Value: Hashable, Content: View>: View {
    var title: String
    @Binding var selection: Value
    @ViewBuilder var content: Content

    init(_ title: String, selection: Binding<Value>, @ViewBuilder content: () -> Content) {
        self.title = title
        _selection = selection
        self.content = content()
    }

    var body: some View {
        Picker(title, selection: $selection) { content }.pickerStyle(.menu)
    }
}

/// 정해진 값 목록에서 고르기. `zero`가 있으면 맨 위에 0 값의 선택지를 둔다 (끄기, 기본값 등).
struct ValueMenu: View {
    var title: String
    var detail: String? = nil
    @Binding var selection: Double
    var values: [Double]
    var zero: String? = nil
    var label: (Double) -> String

    var body: some View {
        Picker(selection: $selection) {
            if let zero { Text(zero).tag(0.0) }
            ForEach(values, id: \.self) { Text(label($0)).tag($0) }
        } label: { RowLabel(title: title, detail: detail) }
    }
}

/// 값이 오른쪽에 보이는 슬라이더
struct ValueSlider: View {
    var title: String
    var detail: String? = nil
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String

    var body: some View {
        LabeledContent {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(format(value)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        } label: { RowLabel(title: title, detail: detail) }
    }
}

/// 일회성 알림의 형태
struct AlertStylePicker: View {
    var title = T("표시 형태", "Style")
    @Binding var selection: AlertStyle

    var body: some View {
        Choice(title, selection: $selection)
    }
}

/// 알림의 표시 시간. 0이면 노치 조작 페이지의 기본 표시 시간을 따른다.
struct AlertDurationMenu: View {
    @Binding var selection: Double

    var body: some View {
        ValueMenu(title: T("표시 시간", "Duration"), selection: $selection, values: Choices.duration,
                  zero: T("기본값", "Default"), label: Format.seconds)
    }
}

/// 진행률의 형태
struct ProgressStylePicker: View {
    @Binding var selection: ProgressStyle

    var body: some View {
        Choice(T("진행률 표시", "Progress"), selection: $selection)
    }
}

/// 쉼표로 나눠 적는 목록. 비어 있어도 입력 칸인 줄 알 수 있게 테두리와 안내 글을 둔다.
struct ListField: View {
    var title: String
    var detail: String? = nil
    @Binding var text: String

    var body: some View {
        LabeledContent {
            TextField("", text: $text, prompt: Text(T("쉼표로 구분", "Comma-separated")))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .labelsHidden()
        } label: { RowLabel(title: title, detail: detail) }
    }
}

/// 설정 → 기능 페이지의 '홈에 이 페이지 표시' 스위치 (홈 기능 페이지의 스위치와 같은 값)
struct HomePageToggle: View {
    @ObservedObject var settings: AppSettings
    var key: String
    var title: String? = nil
    var detail: String? = nil

    var body: some View {
        Toggle(title ?? T("홈에 페이지 표시", "Show page in Home"), detail: detail,
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
