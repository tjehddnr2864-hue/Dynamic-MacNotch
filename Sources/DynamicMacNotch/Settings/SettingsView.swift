import SwiftUI

/// 설정 창. 왼쪽 사이드바(Liquid Glass) + 오른쪽 페이지. 값은 바뀌는 즉시 노치에 반영된다.
/// 페이지는 Settings/Pages/에 하나씩 있다.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var hud: HUDStatus

    #if DEV
    // 개발용: DMN_SETTINGS_PAGE=<페이지>로 특정 페이지를 열어 화면을 확인한다
    private static let startPage = ProcessInfo.processInfo.environment["DMN_SETTINGS_PAGE"].flatMap(SettingsPage.init) ?? .general
    #else
    private static let startPage = SettingsPage.general
    #endif
    private let pageState = State(initialValue: SettingsView.startPage)
    private let expandedState = State(initialValue: SettingsPage.features.contains(SettingsView.startPage) || SettingsView.startPage == .interaction)
    private var page: SettingsPage {
        get { pageState.wrappedValue }
        nonmutating set { pageState.wrappedValue = newValue }
    }
    private var interactionsExpanded: Bool {
        get { expandedState.wrappedValue }
        nonmutating set { expandedState.wrappedValue = newValue }
    }

    static let windowSize = CGSize(width: 860, height: 620)
    /// 사이드바 유리(곡률 18, 안쪽 10pt)와 같은 중심이 되도록 18 + 10
    static let windowCornerRadius: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 214)
                .padding(10)
            VStack(alignment: .leading, spacing: 0) {
                Text(page.title)
                    .font(.title2.bold())
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 스크롤한 내용이 제목 줄 위로 올라와 겹치지 않게 이 경계에서 자른다
                    .clipped()
            }
            .id(page)
        }
        .frame(minWidth: Self.windowSize.width, maxWidth: .infinity, minHeight: Self.windowSize.height, maxHeight: .infinity)
        .background(GlassBackdrop(blur: settings.settingsBlur, transparency: settings.settingsTransparency))
        // 창 배경이 투명하므로 모서리 둥글림을 직접 잘라 준다 (사이드바 유리와 같은 중심의 곡률)
        .clipShape(RoundedRectangle(cornerRadius: Self.windowCornerRadius, style: .continuous))
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .general: GeneralSettingsPage()
        case .displays: DisplaysSettingsPage()
        case .priority: PrioritySettingsPage()
        case .interaction: InteractionsOverview { item in
            withAnimation(.snappy(duration: 0.25)) {
                interactionsExpanded = true
                page = item
            }
        }
        case .home: HomeSettingsPage()
        case .network: NetworkSettingsPage()
        case .bluetooth: BluetoothSettingsPage()
        case .focus: FocusSettingsPage()
        case .call: CallSettingsPage()
        case .media: MediaSettingsPage()
        case .download: DownloadSettingsPage()
        case .airdrop: TraySettingsPage()
        case .screenshot: ScreenshotSettingsPage()
        case .recording: RecordingSettingsPage()
        case .battery: BatterySettingsPage()
        case .hud: HUDSettingsPage(hud: hud) { page = .permissions }
        case .lock: LockSettingsPage()
        case .calendar: CalendarSettingsPage()
        case .aiUsage: UsageSettingsPage()
        case .chat: ChatSettingsPage(settings: settings)
        case .agent: AgentSettingsPage()
        case .preview: PreviewSettingsPage()
        case .permissions: PermissionsView(onboarding: false, embedded: true) {}
        case .about: AboutSettingsPage()
        }
    }

    // MARK: - 사이드바

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 창 버튼(빨강·노랑·초록) 자리: 메뉴는 이 아래에서만 스크롤되어 버튼과 겹치지 않는다
            Color.clear.frame(height: 40)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsPage.top) { item in
                        if item == .interaction {
                            interactionRows
                        } else {
                            sidebarRow(item) { page = item }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }
            .clipped()
        }
        .modifier(LiquidGlassPanel(cornerRadius: 18))
    }

    @ViewBuilder
    private var interactionRows: some View {
        sidebarRow(.interaction, trailing: AnyView(
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(interactionsExpanded ? 90 : 0))
        )) {
            withAnimation(.snappy(duration: 0.25)) {
                interactionsExpanded.toggle()
                page = .interaction
            }
        }
        if interactionsExpanded {
            ForEach(SettingsPage.features) { child in
                sidebarRow(child, indent: 16) { page = child }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func sidebarRow(_ item: SettingsPage, indent: CGFloat = 0, trailing: AnyView? = nil,
                            action: @escaping () -> Void) -> some View {
        let selected = page == item
        return Button(action: action) {
            HStack(spacing: 9) {
                SettingsIcon(page: item, size: 13)
                    .frame(width: 20)
                    .foregroundStyle(selected ? Color.white : Color.accentColor)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if let trailing { trailing }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.leading, 8 + indent)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.85) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 유리 배경

/// 설정 창 전체 배경: 뒤 화면을 흐리게 비추는 층 + 흰색 층.
/// 흐림(blur)은 흐린 층의 불투명도, 투명도(transparency)는 창 색 층을 얼마나 비울지로 조절한다.
private struct GlassBackdrop: View {
    var blur: Double
    var transparency: Double

    var body: some View {
        ZStack {
            BehindWindowBlur().opacity(blur)
            Color.white.opacity(1 - transparency)
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 사이드바 패널: macOS 26 이상은 Liquid Glass, 그 전에는 얇은 머티리얼.
private struct LiquidGlassPanel: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.15)))
        }
    }
}

// MARK: - 아이콘

/// 사이드바·카드 아이콘. SF Symbols에는 블루투스 로고가 없어 직접 그린다.
struct SettingsIcon: View {
    var page: SettingsPage
    var size: CGFloat

    var body: some View {
        if page == .bluetooth {
            BluetoothGlyph()
                .stroke(style: StrokeStyle(lineWidth: max(1.4, size * 0.11), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.62, height: size * 1.05)
        } else {
            Image(systemName: page.symbol).font(.system(size: size, weight: .medium))
        }
    }
}

/// 블루투스 룬 기호
private struct BluetoothGlyph: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        var path = Path()
        path.move(to: p(0, 0.28))
        path.addLine(to: p(1, 0.72))
        path.addLine(to: p(0.5, 1))
        path.addLine(to: p(0.5, 0))
        path.addLine(to: p(1, 0.28))
        path.addLine(to: p(0, 0.72))
        return path
    }
}
