import SwiftUI

/// 설정 창. 왼쪽 시스템 사이드바(묶음 + 검색) + 오른쪽 페이지. 값은 바뀌는 즉시 노치에 반영된다.
/// 페이지는 Settings/Pages/에 하나씩 있다.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var hud: HUDStatus

    #if DEV
    // 개발용: DMN_SETTINGS_PAGE=<페이지>로 특정 페이지를 열어 화면을 확인한다
    private static let startPage = ProcessInfo.processInfo.environment["DMN_SETTINGS_PAGE"].flatMap(SettingsPage.init) ?? lastPage
    // 개발용: DMN_SETTINGS_QUERY=<검색어>로 검색 칸을 채워 연다
    private static let startQuery = ProcessInfo.processInfo.environment["DMN_SETTINGS_QUERY"] ?? ""
    #else
    private static let startPage = lastPage
    private static let startQuery = ""
    #endif
    /// 다시 열면 마지막에 본 페이지로 (HIG: Settings)
    private static var lastPage: SettingsPage { SettingsPage(rawValue: AppSettings.shared.settingsLastPage) ?? .general }
    private let selectionState = State<SettingsPage?>(initialValue: SettingsView.startPage)
    private let queryState = State(initialValue: SettingsView.startQuery)
    private let highlightState = State<String?>(initialValue: nil)
    private var page: SettingsPage { selectionState.wrappedValue ?? .general }
    private var query: String { queryState.wrappedValue.trimmingCharacters(in: .whitespaces) }
    /// 검색 중이면 결과 (설정 창이 열린 동안 키를 칠 때마다 다시 거른다. 색인 약 140개라 바로 끝난다)
    private var results: [SettingsEntry] { query.isEmpty ? [] : SettingsIndex.search(query) }

    static let windowSize = CGSize(width: 860, height: 620)
    /// 창 모서리. macOS 26의 사이드바 유리와 같은 중심이 되는 값
    static let windowCornerRadius: CGFloat = 28
    static let sidebarWidth: CGFloat = 214

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(Self.sidebarWidth)
        } detail: {
            Group {
                if !query.isEmpty {
                    SettingsSearchResults(query: query, results: results, open: open)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        // 폼이 아닌 페이지: 권한 관리는 머리 카드를 위에 고정, 정보는 자체 화면
                        if page == .permissions {
                            PageHeader(page: page).padding(.horizontal, 20).padding(.top, 14)
                        }
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                    .environment(\.settingsPage, page)
                    .environment(\.settingsHighlight, highlightState.wrappedValue)
                    .id(page)
                }
            }
            // 창 제목(화면에는 숨김)은 VoiceOver·창 메뉴가 읽는다. navigationTitle은 도구 막대에 글을 그려 쓰지 않는다
            .background(WindowTitle(title: query.isEmpty ? page.title : T("설정 검색", "Search Settings")))
            // 창 버튼 줄의 빈 도구 막대 자리를 쓰지 않고 제목을 위에 붙인다 (창 버튼은 사이드바 위에 있다)
            .ignoresSafeArea(.container, edges: .top)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .onChange(of: page) { _, new in settings.settingsLastPage = new.rawValue }
        #if DEV
        // 개발용: DMN_SETTINGS_OPEN=<검색 항목 id>면 열린 뒤 그 결과를 연다 (스크롤·강조 시험)
        .onAppear {
            guard let id = ProcessInfo.processInfo.environment["DMN_SETTINGS_OPEN"],
                  let entry = SettingsIndex.all.first(where: { $0.id == id }) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { open(entry) }
        }
        #endif
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

    /// 검색 중이면 결과가 있는 페이지만
    private func visible(_ group: SettingsGroup) -> [SettingsPage] {
        guard !query.isEmpty else { return group.pages }
        let pages = Set(results.map(\.page))
        return group.pages.filter(pages.contains)
    }

    /// 검색 결과 열기: 그 페이지로 가서 줄까지 스크롤하고 잠깐 강조한다
    private func open(_ entry: SettingsEntry) {
        queryState.wrappedValue = ""
        selectionState.wrappedValue = entry.page
        guard !entry.isPage else { return }
        let title = entry.shownTitle
        highlightState.wrappedValue = title
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if highlightState.wrappedValue == title { highlightState.wrappedValue = nil }
        }
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
        .searchable(text: queryState.projectedValue, placement: .sidebar, prompt: T("설정 검색", "Search Settings"))
        .onSubmit(of: .search) { if let first = results.first { open(first) } }   // Return: 첫 결과 열기
    }
}

// MARK: - 유리 배경

/// 설정 창 전체 배경: 뒤 화면을 흐리게 비추는 층 + 창 색 층(라이트는 흰색, 다크는 어두운 색).
/// 흐림(blur)은 흐린 층의 불투명도, 투명도(transparency)는 창 색 층을 얼마나 비울지로 조절한다.
/// 시스템의 '투명도 줄이기'가 켜져 있으면 두 값을 무시하고 불투명하게 그린다.
private struct GlassBackdrop: View {
    var blur: Double
    var transparency: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let window = Color(nsColor: .windowBackgroundColor)
        if reduceTransparency {
            window
        } else {
            ZStack {
                BehindWindowBlur().opacity(blur)
                window.opacity(1 - transparency)
            }
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

// MARK: - 검색 결과

/// 검색 결과 목록: 페이지별로 묶어 줄 이름, 설명, 위치(구역)를 보인다. 누르면 그 줄로 간다.
private struct SettingsSearchResults: View {
    var query: String
    var results: [SettingsEntry]
    var open: (SettingsEntry) -> Void

    private var byPage: [(page: SettingsPage, entries: [SettingsEntry])] {
        var order: [SettingsPage] = []
        var groups: [SettingsPage: [SettingsEntry]] = [:]
        for e in results {
            if groups[e.page] == nil { order.append(e.page) }
            groups[e.page, default: []].append(e)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        if results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text(T("'\(query)'에 맞는 설정이 없습니다", "No settings match '\(query)'")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                Section {
                    Text(T("결과 \(results.count)개 · Return을 누르면 첫 결과로 갑니다", "\(results.count) results · Press Return for the first one"))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(byPage, id: \.page) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            Button { open(entry) } label: {
                                HStack {
                                    RowLabel(title: entry.isPage ? T("페이지 열기", "Open Page") : entry.shownTitle,
                                             detail: entry.isPage ? entry.page.summary : location(entry))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Label { Text(group.page.title) } icon: { SettingsIcon(page: group.page, size: 12).imageScale(.medium) }
                    }
                }
            }
            .settingsForm()
        }
    }

    /// 설명이 있으면 설명, 없으면 위치 (구역 이름)
    private func location(_ e: SettingsEntry) -> String? {
        e.shownDetail ?? e.shownSection
    }
}

/// 창 제목만 바꾼다 (화면에 그리지 않음)
private struct WindowTitle: NSViewRepresentable {
    var title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.title = title }
    }
}
