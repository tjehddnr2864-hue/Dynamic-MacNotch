import SwiftUI

/// 설정 창. 왼쪽 시스템 사이드바(묶음 + 검색) + 오른쪽 페이지. 값은 바뀌는 즉시 노치에 반영된다.
/// 페이지는 Settings/Pages/에 하나씩 있다.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var hud: HUDStatus

    #if DEV
    // 개발용: DMN_SETTINGS_PAGE=<페이지>로 특정 페이지를 열어 화면을 확인한다
    private static let startPage = ProcessInfo.processInfo.environment["DMN_SETTINGS_PAGE"].flatMap(SettingsPage.init) ?? .general
    // 개발용: DMN_SETTINGS_QUERY=<검색어>로 검색 칸을 채워 연다
    private static let startQuery = ProcessInfo.processInfo.environment["DMN_SETTINGS_QUERY"] ?? ""
    #else
    private static let startPage = SettingsPage.general
    private static let startQuery = ""
    #endif
    private let selectionState = State<SettingsPage?>(initialValue: SettingsView.startPage)
    private let queryState = State(initialValue: SettingsView.startQuery)
    private var page: SettingsPage { selectionState.wrappedValue ?? .general }

    static let windowSize = CGSize(width: 860, height: 620)
    /// 창 모서리. macOS 26의 사이드바 유리와 같은 중심이 되는 값
    static let windowCornerRadius: CGFloat = 28
    static let sidebarWidth: CGFloat = 214

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(Self.sidebarWidth)
        } detail: {
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
            // 창 버튼 줄의 빈 도구 막대 자리를 쓰지 않고 제목을 위에 붙인다 (창 버튼은 사이드바 위에 있다)
            .ignoresSafeArea(.container, edges: .top)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: Self.windowSize.width, maxWidth: .infinity, minHeight: Self.windowSize.height, maxHeight: .infinity)
        .background(GlassBackdrop(blur: settings.settingsBlur, transparency: settings.settingsTransparency))
        // 창 배경이 투명하므로 모서리 둥글림을 직접 잘라 준다
        .clipShape(RoundedRectangle(cornerRadius: Self.windowCornerRadius, style: .continuous))
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .general: GeneralSettingsPage()
        case .displays: DisplaysSettingsPage()
        case .permissions: PermissionsView(onboarding: false, embedded: true) {}
        case .notchControls: NotchControlsSettingsPage()
        case .home: HomeSettingsPage()
        case .priority: PrioritySettingsPage()
        case .network: NetworkSettingsPage()
        case .bluetooth: BluetoothSettingsPage()
        case .call: CallSettingsPage()
        case .airdrop: TraySettingsPage()
        case .media: MediaSettingsPage()
        case .screenshot: ScreenshotSettingsPage()
        case .recording: RecordingSettingsPage()
        case .download: DownloadSettingsPage()
        case .battery: BatterySettingsPage()
        case .focus: FocusSettingsPage()
        case .hud: HUDSettingsPage(hud: hud) { selectionState.wrappedValue = .permissions }
        case .lock: LockSettingsPage()
        case .calendar: CalendarSettingsPage()
        case .aiUsage: MonitoringSettingsPage()
        case .chat: ChatSettingsPage(settings: settings)
        case .agent: AgentSettingsPage()
        case .preview: PreviewSettingsPage()
        case .about: AboutSettingsPage()
        }
    }

    // MARK: - 사이드바 (시스템 사이드바: macOS 26 이상은 Liquid Glass를 저절로 입는다)

    /// 검색어가 있으면 이름이 맞는 페이지만 (전체 설정 검색은 단계 6)
    private func visible(_ group: SettingsGroup) -> [SettingsPage] {
        let q = queryState.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return group.pages }
        return group.pages.filter { $0.title.localizedStandardContains(q) }
    }

    private func expanded(_ group: SettingsGroup) -> Binding<Bool> {
        Binding(get: { !settings.settingsCollapsedGroups.contains(group.rawValue) || !queryState.wrappedValue.isEmpty },
                set: { open in
                    settings.settingsCollapsedGroups = settings.settingsCollapsedGroups.filter { $0 != group.rawValue } + (open ? [] : [group.rawValue])
                })
    }

    private var sidebar: some View {
        List(selection: selectionState.projectedValue) {
            ForEach(SettingsGroup.allCases) { group in
                let pages = visible(group)
                if !pages.isEmpty {
                    Section(isExpanded: expanded(group)) {
                        ForEach(pages) { item in
                            Label {
                                Text(item.title).lineLimit(1)
                            } icon: {
                                // 시스템 사이드바는 아이콘을 키운다(imageScale .large). 기존 크기 13pt를 지킨다
                                SettingsIcon(page: item, size: 13).imageScale(.medium)
                            }
                            .tag(item)
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: queryState.projectedValue, placement: .sidebar, prompt: T("검색", "Search"))
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
