import SwiftUI

/// 설정 창 페이지. '상호작용'은 기능별 페이지를 펼치는 묶음이다.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, priority, interaction
    case network, bluetooth, focus, call, media, download, airdrop, screenshot, recording, battery, hud, lock, aiUsage, agent
    case test, permissions, about

    var id: String { rawValue }

    /// '상호작용' 아래에 펼쳐지는 기능별 페이지
    static let features: [SettingsPage] = [.network, .bluetooth, .focus, .call, .media, .download, .airdrop,
                                           .screenshot, .recording, .battery, .hud, .lock, .aiUsage, .agent]
    static let top: [SettingsPage] = [.general, .priority, .interaction, .test, .permissions, .about]

    var title: String {
        switch self {
        case .general: return T("일반", "General")
        case .priority: return T("우선순위", "Priority")
        case .interaction: return T("상호작용", "Interactions")
        case .network: return T("네트워크", "Network")
        case .bluetooth: return T("블루투스", "Bluetooth")
        case .focus: return T("방해금지 모드", "Focus")
        case .call: return T("전화", "Phone Calls")
        case .media: return T("미디어", "Media")
        case .download: return T("다운로드", "Downloads")
        case .airdrop: return T("에어드랍 및 파일 트레이", "AirDrop & File Tray")
        case .screenshot: return T("스크린샷", "Screenshots")
        case .recording: return T("화면 녹화", "Screen Recording")
        case .battery: return T("배터리 및 충전", "Battery & Charging")
        case .hud: return "HUD"
        case .lock: return T("잠금화면", "Lock Screen")
        case .aiUsage: return T("AI 사용량", "AI Usage")
        case .agent: return "Claude Code · Codex"
        case .test: return T("테스트", "Test")
        case .permissions: return T("권한 관리", "Permissions")
        case .about: return T("정보", "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .priority: return "list.number"
        case .interaction: return "bell.badge"
        case .network: return "wifi"
        case .bluetooth: return "airpodspro"
        case .focus: return "moon"
        case .call: return "phone"
        case .media: return "music.note"
        case .download: return "arrow.down.circle"
        case .airdrop: return "tray.and.arrow.down"
        case .screenshot: return "camera.viewfinder"
        case .recording: return "record.circle"
        case .battery: return "battery.75percent"
        case .hud: return "speaker.wave.2"
        case .lock: return "lock"
        case .aiUsage: return "gauge.medium"
        case .agent: return "terminal"
        case .test: return "play.rectangle"
        case .permissions: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}

/// 설정 창. 왼쪽 사이드바(Liquid Glass) + 오른쪽 페이지. 값은 바뀌는 즉시 노치에 반영된다.
/// 기능별 페이지는 같은 순서로 구성한다: 표시 → 표시 방식 → 세부 설정 → 미리보기.
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var hud: HUDStatus
    var preview: (String) -> Void

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
                    .padding(.bottom, 2)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .id(page)
        }
        .frame(minWidth: Self.windowSize.width, maxWidth: .infinity, minHeight: Self.windowSize.height, maxHeight: .infinity)
        .background(GlassBackdrop(blur: settings.settingsBlur, transparency: settings.settingsTransparency))
        // 창 배경이 투명하므로 모서리 둥글림을 직접 잘라 준다 (사이드바 유리와 같은 중심의 곡률)
        .clipShape(RoundedRectangle(cornerRadius: Self.windowCornerRadius, style: .continuous))
        .ignoresSafeArea()
    }

    // MARK: - 사이드바

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPage.top) { item in
                    if item == .interaction {
                        sidebarRow(item, trailing: AnyView(
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
                    } else {
                        sidebarRow(item) { page = item }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 42)   // 사이드바 위쪽에 놓인 창 버튼(빨강·노랑·초록) 자리
            .padding(.bottom, 8)
        }
        .modifier(LiquidGlassPanel(cornerRadius: 18))
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

    @ViewBuilder
    private var content: some View {
        switch page {
        case .general: general
        case .priority: priority
        case .interaction: interactionOverview
        case .network: network
        case .bluetooth: bluetooth
        case .focus: focus
        case .call: call
        case .media: media
        case .download: download
        case .airdrop: airdrop
        case .screenshot: screenshot
        case .recording: recording
        case .battery: battery
        case .hud: hudPage
        case .lock: lockPage
        case .aiUsage: aiUsagePage
        case .agent: AgentSettingsPage(settings: settings, preview: preview)
        case .test: testTab
        case .permissions: PermissionsView(onboarding: false, embedded: true) {}
        case .about: about
        }
    }

    // MARK: - 일반

    /// 이 설정 창이 열릴 때의 언어 (바뀌었는지 비교용)
    private static let launchLanguage = AppSettings.shared.language

    private var general: some View {
        Form {
            Section {
                Picker(T("언어", "Language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                if settings.language != Self.launchLanguage {
                    HStack {
                        Text(T("다시 시작하면 적용됩니다.", "Applies after restarting the app."))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(T("지금 다시 시작", "Restart Now")) {
                            Helper.sendToMain("restart")
                            NSApp.terminate(nil)   // 설정 창(도우미)도 닫는다
                        }
                    }
                }
                Picker(T("표시 화면", "Display"), selection: $settings.displayTarget) {
                    ForEach(DisplayTarget.allCases) { Text($0.label).tag($0) }
                }
                Picker(T("일회성 알림 표시 시간", "Alert Duration"), selection: $settings.transientDuration) {
                    ForEach([1.5, 2.5, 4.0, 6.0], id: \.self) { Text(L10n.seconds($0, digits: 1)).tag($0) }
                }
                Toggle(T("메뉴바 아이콘 표시", "Show Menu Bar Icon"), isOn: $settings.showStatusItem)
                Toggle(T("자동 업데이트 (하루 한 번 확인)", "Automatic updates (checks daily)"), isOn: $settings.autoUpdate)
                Toggle(T("메모리 자동 최적화 (기준을 넘으면 쉬는 동안 조용히 다시 시작)", "Automatic memory cleanup (quietly restarts while idle above the limit)"), isOn: $settings.memoryGuard)
                Picker(T("최적화 기준", "Cleanup Limit"), selection: $settings.memoryLimitMB) {
                    ForEach([70.0, 80.0, 90.0, 100.0, 110.0, 120.0, 130.0, 140.0, 150.0], id: \.self) { Text("\(Int($0)) MB").tag($0) }
                }
                .disabled(!settings.memoryGuard)
            }
            Section {
                LabeledContent(T("길게누르기 시간", "Long-Press Duration")) {
                    HStack {
                        Slider(value: $settings.longPressDuration, in: 0.2...0.8, step: 0.05)
                        Text(L10n.seconds(settings.longPressDuration, digits: 2)).monospacedDigit().frame(width: 52)
                    }
                }
                Toggle(T("깊게누르기(포스터치)로 바로 열기", "Open with Force Click"), isOn: $settings.forceTouchEnabled)
                Picker(T("햅틱 강도", "Haptic Strength"), selection: $settings.hapticStrength) {
                    ForEach(HapticStrength.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(T("호버 시 살짝 커지는 미리보기", "Grow slightly on hover"), isOn: $settings.hoverPreview)
                Toggle(T("호버만으로 열기", "Open on hover"), isOn: $settings.hoverToOpen)
            } header: {
                Text(T("노치 조작", "Notch Controls"))
            } footer: {
                Text(T("마우스는 압력 이벤트가 없어 길게누르기만 동작합니다.", "Mice don't report pressure, so only long-press works with a mouse."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(T("노치 홈", "Notch Home")) {
                Toggle(T("카메라 좌우 반전(거울)", "Mirror camera"), isOn: $settings.cameraMirror)
                Picker(T("일정 알림", "Event Alerts"), selection: $settings.calendarAlertMinutes) {
                    Text(T("끄기", "Off")).tag(0.0)
                    ForEach([5.0, 10.0, 15.0], id: \.self) { Text(T("\(Int($0))분 전", "\(Int($0)) min before")).tag($0) }
                }
            }
            Section {
                percentSlider(T("배경 흐림", "Background Blur"), value: $settings.settingsBlur, range: 0...1)
                percentSlider(T("투명도", "Transparency"), value: $settings.settingsTransparency, range: 0...0.9)
            } header: {
                Text(T("설정 창 (Liquid Glass)", "Settings Window (Liquid Glass)"))
            } footer: {
                Text(T("흐림을 낮추면 뒤 화면이 또렷하게, 투명도를 높이면 더 많이 비쳐 보입니다.", "Lower blur shows the screen behind more sharply; higher transparency lets more of it through."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsForm()
    }

    private func percentSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: 0.05)
                Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().frame(width: 44)
            }
        }
    }

    // MARK: - 우선순위

    private var priority: some View {
        Form {
            Section {
                ForEach(Array(settings.persistentOrder.enumerated()), id: \.element) { index, key in
                    HStack {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
                        Label(Self.persistentName(key), systemImage: Self.persistentSymbol(key))
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == settings.persistentOrder.count - 1)
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text(T("상시 표시 우선순위", "Live Activity Priority"))
            } footer: {
                Text(T("여러 항목이 동시에 진행 중이면 위에 있는 항목이 노치에 표시됩니다. 노치 위에서 두 손가락으로 위로 쓸면 숨기고, 아래로 쓸면 다시 나타납니다.", "When several activities run at once, the one higher in the list is shown. Swipe up with two fingers on the notch to hide them, and swipe down to show them again."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsForm()
    }

    private func move(_ index: Int, by delta: Int) {
        var order = settings.persistentOrder
        let target = index + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        withAnimation { settings.persistentOrder = order }
    }

    static func persistentName(_ key: String) -> String {
        switch key {
        case "call": return T("통화", "Phone Call")
        case "recording": return T("화면 녹화", "Screen Recording")
        case "timer": return T("타이머", "Timer")
        case "airdrop": return T("에어드랍 전송", "AirDrop Transfer")
        case "download": return T("다운로드", "Download")
        case "media": return T("음악 재생", "Music")
        case "hotspot": return T("핫스팟 연결", "Hotspot")
        case "focusPinned": return T("집중 모드", "Focus")
        case "aiUsage": return T("AI 사용량", "AI Usage")
        default: return key
        }
    }

    static func persistentSymbol(_ key: String) -> String {
        switch key {
        case "call": return "phone.fill"
        case "recording": return "record.circle"
        case "timer": return "timer"
        case "airdrop": return "airplayaudio"
        case "download": return "arrow.down.circle"
        case "media": return "music.note"
        case "hotspot": return "personalhotspot"
        case "focusPinned": return "moon"
        case "aiUsage": return "gauge.medium"
        default: return "circle"
        }
    }

    // MARK: - 상호작용 (기능별 페이지 모음)

    private var interactionOverview: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(SettingsPage.features) { item in
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            interactionsExpanded = true
                            page = item
                        }
                    } label: {
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
            Text(T("각 기능을 눌러 표시 여부, 표시 방식, 세부 설정을 바꾸고 바로 미리 볼 수 있습니다.",
                   "Choose a feature to change whether and how it appears, adjust its details and preview it."))
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }
    }

    // 기능별 페이지 공통 부품 (순서: 표시 → 표시 방식 → 세부 설정 → 미리보기)

    private var showHeader: Text { Text(T("표시", "Show")) }
    private var styleHeader: Text { Text(T("표시 방식", "Appearance")) }
    private var detailHeader: Text { Text(T("세부 설정", "Details")) }

    private func alertStylePicker(_ selection: Binding<AlertStyle>) -> some View {
        Picker(T("표시 형태", "Style"), selection: selection) {
            ForEach(AlertStyle.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private func durationPicker(_ selection: Binding<Double>) -> some View {
        Picker(T("표시 시간", "Duration"), selection: selection) {
            Text(T("일반 설정 따름", "Use General Setting")).tag(0.0)
            ForEach([1.5, 2.5, 4.0, 6.0], id: \.self) { Text(L10n.seconds($0, digits: 1)).tag($0) }
        }
    }

    private func progressPicker(_ selection: Binding<ProgressStyle>) -> some View {
        Picker(T("진행률", "Progress"), selection: selection) {
            ForEach(ProgressStyle.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    /// 미리보기 버튼 줄 (각 페이지 맨 아래). 현재 설정 그대로 보여 준다.
    private func previewSection(_ items: [(id: String, label: String)]) -> some View {
        Section(T("미리보기", "Preview")) {
            HStack(spacing: 8) {
                ForEach(items, id: \.id) { item in
                    Button(item.label) { preview(item.id) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: 네트워크

    private var network: some View {
        Form {
            Section {
                Toggle(T("Wi-Fi 켜짐 / 꺼짐", "Wi-Fi On / Off"), isOn: $settings.netWifiPower)
                Toggle(T("Wi-Fi 연결됨 / 연결 해제됨", "Wi-Fi Connected / Disconnected"), isOn: $settings.netWifiConnection)
                Toggle(T("VPN 연결됨 / 연결 해제됨", "VPN Connected / Disconnected"), isOn: $settings.netVPN)
                Toggle(T("핫스팟 연결됨 / 연결 해제됨", "Hotspot Connected / Disconnected"), isOn: $settings.netHotspot)
            } header: { showHeader }
            Section {
                alertStylePicker($settings.netStyle)
                durationPicker($settings.netDuration)
            } header: { styleHeader }
            Section {
                Toggle(T("핫스팟 연결 중 상시 표시", "Keep showing while on a hotspot"), isOn: $settings.hotspotPinned)
                TextField(T("핫스팟으로 볼 Wi-Fi 이름(쉼표 구분)", "Wi-Fi names to treat as hotspots (comma-separated)"), text: $settings.hotspotSSIDs)
            } header: { detailHeader } footer: {
                footnote(T("핫스팟은 '데이터 절약 네트워크' 여부로 추정합니다. 잘 안 잡히면 iPhone의 Wi-Fi 이름을 적어 주세요. Wi-Fi 이름 표시에는 위치 서비스 권한이 필요합니다.", "Hotspots are detected from the 'Low Data Mode' network flag. If yours isn't detected, enter your iPhone's Wi-Fi name. Showing Wi-Fi names requires Location Services permission."))
            }
            previewSection([("wifi-connected", T("Wi-Fi 연결", "Wi-Fi Connected")), ("vpn-on", T("VPN 연결", "VPN Connected")),
                            ("hotspot", T("핫스팟", "Hotspot")), ("offline", T("네트워크 끊김", "Network Lost"))])
        }
        .settingsForm()
    }

    // MARK: 블루투스

    private var bluetooth: some View {
        Form {
            Section {
                Toggle(T("액세서리 연결 시 표시", "Show when an accessory connects"), isOn: $settings.btEnabled)
            } header: { showHeader }
            Section {
                alertStylePicker($settings.btStyle)
                Picker(T("배터리 표시", "Battery Display"), selection: $settings.btBattery) {
                    ForEach(BatteryDisplay.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { styleHeader }
            Section {
                TextField(T("알림 끌 기기 이름(쉼표 구분)", "Devices to ignore (comma-separated)"), text: $settings.btBlocklist)
            } header: { detailHeader }
            previewSection([("bt-airpods", "AirPods"), ("bt-low", T("배터리 낮은 마우스", "Low-Battery Mouse")),
                            ("bt-nobattery", T("배터리 정보 없음", "No Battery Info"))])
        }
        .settingsForm()
    }

    // MARK: 방해금지 모드

    private var focus: some View {
        Form {
            Section {
                Toggle(T("켜짐 / 꺼짐 표시", "Show On / Off"), isOn: $settings.focusEnabled)
            } header: { showHeader }
            Section {
                alertStylePicker($settings.focusStyle)
                durationPicker($settings.focusDuration)
            } header: { styleHeader }
            Section {
                Toggle(T("집중 모드 켜진 동안 상시 표시", "Keep showing while Focus is on"), isOn: $settings.focusPinned)
                TextField(T("표시하지 않을 모드 이름(쉼표 구분)", "Modes to ignore (comma-separated)"), text: $settings.focusExcluded)
            } header: { detailHeader } footer: {
                footnote(T("모드 이름·아이콘은 전체 디스크 접근 권한이 있을 때만 표시됩니다. 없으면 '집중 모드 켬/끔'으로 표시합니다.", "Mode names and icons require Full Disk Access. Without it, alerts just say 'Focus On/Off'."))
            }
            previewSection([("focus-on", T("켜짐", "On")), ("focus-off", T("꺼짐", "Off"))])
        }
        .settingsForm()
    }

    // MARK: 전화

    private var call: some View {
        Form {
            Section {
                Toggle(T("전화 수신·통화 표시 (iPhone 연속성·FaceTime 오디오)", "Show incoming and active calls (iPhone Continuity, FaceTime audio)"), isOn: $settings.callEnabled)
            } header: { showHeader } footer: {
                footnote(T("수신 전화는 상세 카드(받기·거절), 통화 중에는 노치 양옆에 경과 시간을 표시합니다. 손쉬운 사용 권한이 필요합니다.", "Incoming calls show a detailed card (Accept, Decline); during a call the notch shows the elapsed time. Requires Accessibility permission."))
            }
            previewSection([("call-incoming", T("수신 전화", "Incoming Call")), ("call-active", T("통화 중", "On a Call"))])
        }
        .settingsForm()
    }

    // MARK: 미디어

    private var media: some View {
        Form {
            Section {
                Toggle(T("곡이 바뀌면 잠깐 크게 표시", "Briefly show the new song"), isOn: $settings.mediaShowTrackChange)
                Toggle(T("Apple Music·Spotify에서만", "Only for Apple Music and Spotify"), isOn: $settings.mediaTrackChangeMusicOnly)
                    .padding(.leading, 16)
                    .disabled(!settings.mediaShowTrackChange)
            } header: { showHeader }
            Section {
                Picker(T("일시정지 후 숨김", "Hide After Pause"), selection: $settings.mediaHideAfterPause) {
                    Text(T("숨기지 않음", "Never")).tag(0.0)
                    ForEach([10.0, 30.0, 60.0], id: \.self) { Text(T("\(Int($0))초", "\(Int($0))s")).tag($0) }
                }
            } header: { styleHeader }
            Section {
                Picker(T("재생 소스", "Source"), selection: $settings.mediaSource) {
                    ForEach(MediaSource.allCases) { Text($0.label).tag($0) }
                }
            } header: { detailHeader }
            previewSection([("media-start", T("재생 테스트 시작", "Start Playback Test")), ("media-stop", T("테스트 중지", "Stop Test"))])
        }
        .settingsForm()
    }

    // MARK: 다운로드

    private var download: some View {
        Form {
            Section {
                Toggle(T("다운로드 진행 표시", "Show download progress"), isOn: $settings.downloadEnabled)
            } header: { showHeader }
            Section {
                progressPicker($settings.downloadStyle)
            } header: { styleHeader }
            Section {
                FolderSetting(title: T("바로가기 경로", "Shortcut Folder"), path: $settings.downloadFolder,
                              defaultPath: AppSettings.defaultDownloadFolder)
                TextField(T("추가 감시 폴더(쉼표 구분 경로)", "Extra folders to watch (comma-separated paths)"), text: $settings.downloadFolders)
            } header: { detailHeader }
            previewSection([("download", T("다운로드", "Download"))])
        }
        .settingsForm()
    }

    // MARK: 에어드랍 및 파일 트레이

    private var airdrop: some View {
        Form {
            Section {
                progressPicker($settings.airdropStyle)
            } header: { styleHeader }
            Section {
                Toggle(T("트레이에 복사본 보관(원본이 옮겨져도 유지)", "Keep copies in the tray (survive moves)"), isOn: $settings.trayKeepCopies)
                Picker(T("트레이 자동 정리", "Auto-Clean Tray"), selection: $settings.trayCleanupDays) {
                    Text(T("끄기", "Off")).tag(0.0)
                    Text(T("1일", "1 day")).tag(1.0)
                    Text(T("7일", "7 days")).tag(7.0)
                }
                LabeledContent(T("드래그 감지 높이", "Drag Detection Height")) {
                    HStack {
                        Slider(value: $settings.dragZoneHeight, in: 60...200, step: 10)
                        Text("\(Int(settings.dragZoneHeight))pt").monospacedDigit().frame(width: 44)
                    }
                }
            } header: { detailHeader } footer: {
                footnote(T("파일을 들고 화면 위쪽 감지 높이 안으로 오면, 가장자리에 닿기 전에 노치가 먼저 열려 미션 컨트롤이 뜨지 않게 합니다.", "When you drag a file into this zone at the top of the screen, the notch opens before you reach the edge, so Mission Control doesn't trigger."))
            }
            previewSection([("airdrop-send", T("에어드랍 보내기", "AirDrop Send")), ("airdrop-receive", T("에어드랍 받기", "AirDrop Receive"))])
        }
        .settingsForm()
    }

    // MARK: 스크린샷

    private var screenshot: some View {
        Form {
            Section {
                Toggle(T("스크린샷 미리보기", "Screenshot preview"), isOn: $settings.screenshotEnabled)
            } header: { showHeader }
            Section {
                Picker(T("자동 닫힘", "Auto-Close"), selection: $settings.screenshotAutoClose) {
                    ForEach([5.0, 10.0, 30.0], id: \.self) { Text(T("\(Int($0))초", "\(Int($0))s")).tag($0) }
                }
            } header: { styleHeader }
            Section {
                Picker(T("감지 대상", "Detect"), selection: $settings.screenshotSource) {
                    ForEach(ScreenshotSource.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                FolderSetting(title: T("저장 폴더", "Save Folder"), path: $settings.screenshotFolder,
                              defaultPath: AppSettings.defaultRecordingFolder)
                Toggle(T("JPEG로 저장", "Save as JPEG"), isOn: $settings.screenshotJPEG)
            } header: { detailHeader }
            .disabled(!settings.screenshotEnabled)
            previewSection([("screenshot", T("스크린샷", "Screenshot"))])
        }
        .settingsForm()
    }

    // MARK: 화면 녹화

    private var recording: some View {
        Form {
            Section {
                Toggle(T("화면 녹화 표시", "Show screen recording"), isOn: $settings.recordingEnabled)
            } header: { showHeader }
            Section {
                Picker(T("표시 형태", "Style"), selection: $settings.recordingStyle) {
                    ForEach(RecordingStyle.allCases) { Text($0.label).tag($0) }
                }
            } header: { styleHeader }
            .disabled(!settings.recordingEnabled)
            Section {
                FolderSetting(title: T("바로가기 경로", "Shortcut Folder"), path: $settings.recordingFolder,
                              defaultPath: AppSettings.defaultRecordingFolder)
            } header: { detailHeader }
            .disabled(!settings.recordingEnabled)
            previewSection([("recording", T("화면 녹화", "Screen Recording"))])
        }
        .settingsForm()
    }

    // MARK: 배터리 및 충전

    private var battery: some View {
        Form {
            Section {
                Toggle(T("충전기 연결 알림", "Charger connected alert"), isOn: $settings.batteryChargerAlert)
                Toggle(T("완충 알림", "Fully charged alert"), isOn: $settings.batteryFullAlert)
                Toggle(T("배터리 부족 경고", "Low battery warning"), isOn: $settings.batteryLowAlert)
            } header: { showHeader }
            Section {
                alertStylePicker($settings.batteryStyle)
            } header: { styleHeader }
            Section {
                LabeledContent(T("부족 경고 기준", "Low Battery Level")) {
                    HStack {
                        Slider(value: $settings.batteryLowThreshold, in: 5...50, step: 5)
                        Text("\(Int(settings.batteryLowThreshold))%").monospacedDigit().frame(width: 40)
                    }
                }
                .disabled(!settings.batteryLowAlert)
            } header: { detailHeader }
            previewSection([("charger", T("충전기 연결", "Charger Connected")), ("low", T("배터리 부족", "Low Battery")), ("full", T("완충", "Full"))])
        }
        .settingsForm()
    }

    // MARK: HUD

    private var hudPage: some View {
        Form {
            Section {
                LabeledContent(T("상태", "Status")) {
                    HStack {
                        Text(hud.active ? T("동작 중", "Active") : T("손쉬운 사용 권한 필요", "Accessibility permission needed"))
                            .foregroundStyle(hud.active ? .green : .orange)
                        if !hud.active {
                            Button(T("권한 관리…", "Permissions…")) { page = .permissions }
                        }
                    }
                }
                Toggle(T("음량", "Volume"), isOn: $settings.hudVolume)
                Toggle(T("화면 밝기", "Display Brightness"), isOn: $settings.hudDisplay)
                Toggle(T("키보드 밝기", "Keyboard Brightness"), isOn: $settings.hudKeyboard)
            } header: { showHeader }
            Section {
                Picker(T("수치 표시", "Value Style"), selection: $settings.hudStyle) {
                    ForEach(HUDStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(T("표시 시간", "Duration"), selection: $settings.hudDuration) {
                    ForEach([1.0, 1.5, 2.5, 4.0], id: \.self) { Text(L10n.seconds($0, digits: 1)).tag($0) }
                }
            } header: { styleHeader }
            Section {
                Toggle(T("음량 HUD에 출력 기기 아이콘 표시", "Show output device icon in volume HUD"), isOn: $settings.hudOutputIcon)
                Toggle(T("제어 센터에서 직접 바꾼 화면 밝기도 표시", "Also show display brightness changed in Control Center"), isOn: $settings.hudDisplayExternal)
                Toggle(T("제어 센터에서 직접 바꾼 키보드 밝기도 표시", "Also show keyboard brightness changed in Control Center"), isOn: $settings.hudKeyboardExternal)
            } header: { detailHeader } footer: {
                footnote(T("자동 밝기로 바뀐 값은 표시하지 않습니다.", "Changes made by automatic brightness are not shown."))
            }
            previewSection([("hud-volume", T("음량", "Volume")), ("hud-brightness", T("화면 밝기", "Display Brightness")),
                            ("hud-keyboard", T("키보드 밝기", "Keyboard Brightness"))])
        }
        .settingsForm()
    }

    // MARK: AI 사용량

    private var aiUsagePage: some View {
        let connected = AIService.connected(settings.aiConnected)
        return Form {
            Section {
                Toggle(T("노치에 상시 표시 (왼쪽 5시간 · 오른쪽 주간 한도, 한도가 하나면 오른쪽은 초기화까지 남은 시간)",
                         "Keep showing in the notch (left: 5-hour, right: weekly; with a single limit, the right shows time to reset)"),
                       isOn: $settings.aiUsagePinned)
            } header: { showHeader } footer: {
                footnote(T("상시 표시를 끄면 백그라운드에서 새로고침하지 않고, 노치를 길게 눌러 AI 사용량 페이지를 열 때만 새로고침합니다. 두 손가락으로 잠시 가려 둔 동안에는 계속 새로고침하고, 우선순위가 더 높은 상시 항목에 가려진 동안에는 쉬었다가 다시 보이면 이어서 합니다.",
                           "When this is off, nothing refreshes in the background; usage refreshes only when you long-press the notch and open the AI Usage page. While hidden with a two-finger swipe it keeps refreshing; while covered by a higher-priority item it pauses and resumes once visible again."))
            }
            Section {
                Picker(T("사용량 표시", "Usage Display"), selection: $settings.aiUsageStyle) {
                    ForEach(UsageStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(T("상시 표시할 서비스", "Service to Show"), selection: $settings.aiUsageService) {
                    ForEach(AIService.allCases) { Text($0.name).tag($0.rawValue) }
                }
            } header: { styleHeader }
            Section {
                Picker(T("새로고침 빈도", "Refresh Every"), selection: $settings.aiRefreshMinutes) {
                    ForEach([1.0, 2.0, 5.0, 10.0], id: \.self) { Text(T("\(Int($0))분", "\(Int($0)) min")).tag($0) }
                }
                ForEach(AIService.allCases) { service in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(connected.contains(service) ? T("연결됨", "Connected") : T("연결 안 됨", "Not connected"))
                                .foregroundStyle(connected.contains(service) ? .green : .secondary)
                            if connected.contains(service) {
                                Button(T("로그아웃", "Sign Out")) { signOut(service) }
                            } else {
                                Button(T("로그인…", "Sign In…")) { UsageLoginWindow.show(service) }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(service.tint).frame(width: 8, height: 8)
                            Text(service.name)
                        }
                    }
                }
            } header: { detailHeader } footer: {
                footnote(T("각 서비스 웹사이트에 로그인해 연동합니다. 로그인 정보는 이 앱 전용 웹 저장소에만 남으며, 사용량은 Claude(claude.ai 사용량), ChatGPT(Codex 사용 한도), Gemini(gemini.google.com/usage)에서 읽습니다.",
                           "Sign in on each service's website. Sign-in data stays in this app's own web storage. Usage is read from Claude (claude.ai usage), ChatGPT (Codex usage limits) and Gemini (gemini.google.com/usage)."))
            }
            previewSection([("ai-usage", T("상시 표시", "Live Display"))])
        }
        .settingsForm()
    }

    private func signOut(_ service: AIService) {
        UsageWeb.signOut(service) {}
        settings.aiConnected = AppSettings.list(settings.aiConnected).filter { $0 != service.rawValue }.joined(separator: ",")
    }

    // MARK: 잠금화면

    private var lockPage: some View {
        Form {
            Section {
                Toggle(T("잠기면 자물쇠 표시, 풀리면 열림 애니메이션", "Show a lock when locked and an unlock animation"), isOn: $settings.lockNotchEnabled)
                Toggle(T("음악 재생 중 잠금화면 미디어 위젯", "Lock screen media widget while playing"), isOn: $settings.lockMediaWidget)
            } header: { showHeader }
            Section {
                Toggle(T("잠금화면에서 곡 정보 숨기기", "Hide song info on the lock screen"), isOn: $settings.lockHideTrackInfo)
            } header: { styleHeader } footer: {
                footnote(T("위젯은 프로필 사진·암호 입력란 바로 위에 표시됩니다. 앨범아트를 누르면 전체화면 플레이어로 커집니다. 잠금화면에 창을 띄우는 기능은 비공개 API를 쓰므로 macOS 업데이트에 따라 동작하지 않을 수 있습니다.", "The widget appears just above your profile picture and password field. Click the album art for a full-screen player. Showing windows on the lock screen uses private APIs and may stop working after a macOS update."))
            }
            .disabled(!settings.lockMediaWidget)
            Section {
                Toggle(T("전체화면에서 가사 표시 (Apple Music)", "Show lyrics in full screen (Apple Music)"), isOn: $settings.lyricsEnabled)
                Toggle(T("실시간(시간 동기) 가사 가져오기", "Fetch live (time-synced) lyrics"), isOn: $settings.lyricsOnline)
                Picker(T("가사 글자 크기", "Lyrics Size"), selection: $settings.lyricsSize) {
                    Text(T("작게", "Small")).tag(0)
                    Text(T("보통", "Medium")).tag(1)
                    Text(T("크게", "Large")).tag(2)
                }
                .pickerStyle(.segmented)
            } header: { detailHeader } footer: {
                footnote(T("실시간 가사는 곡 제목·아티스트·앨범을 외부 가사 서비스 LRCLIB(lrclib.net)로 보내 받아옵니다. 끄면 Music 앱에 저장된 가사만 표시합니다.", "Live lyrics send the song title, artist and album to LRCLIB (lrclib.net). When off, only lyrics stored in the Music app are shown."))
            }
            .disabled(!settings.lockMediaWidget)
            previewSection([("lock", T("자물쇠·위젯 (5초)", "Padlock & Widget (5s)"))])
        }
        .settingsForm()
    }

    // MARK: - 테스트 (기능별 미리보기)

    private var testTab: some View {
        Form {
            Section {
                HStack {
                    Text(T("각 버튼을 누르면 노치에 해당 기능이 미리 표시됩니다. 실제 설정·파일·통화에는 영향이 없습니다.",
                           "Each button previews that feature in the notch. Your real settings, files and calls are not affected."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(T("모든 미리보기 중지", "Stop All Previews")) { preview("stop-all") }
                }
            }
            Section(T("음악", "Music")) {
                HStack {
                    Button(T("재생 테스트 시작", "Start Playback Test")) { preview("media-start") }
                    Button(T("테스트 중지", "Stop Test")) { preview("media-stop") }
                }
                Text(T("테스트 곡이 노치에 재생됩니다. 길게 눌러 플레이어를 열고 재생·다음·이전·재생 바를 시험해 보세요. 30초 동안 조작이 없으면 자동으로 중지됩니다.",
                       "A test song plays in the notch. Long-press to open the player and try play, next, previous and the progress bar. It stops automatically after 30 seconds without interaction."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            // 컴팩트·상세를 고를 수 있는 알림: 묶음마다 형태를 골라 미리 본다 (실제 설정은 바뀌지 않음)
            StylePreviewSection(title: T("네트워크", "Network"), initial: settings.netStyle, preview: preview,
                                items: [("wifi-on", T("Wi-Fi 켜짐", "Wi-Fi On")), ("wifi-off", T("Wi-Fi 꺼짐", "Wi-Fi Off")),
                                        ("wifi-connected", T("Wi-Fi 연결", "Wi-Fi Connected")), ("wifi-disconnected", T("Wi-Fi 해제", "Wi-Fi Disconnected")),
                                        ("vpn-on", T("VPN 연결", "VPN Connected")), ("vpn-off", T("VPN 해제", "VPN Disconnected")),
                                        ("hotspot", T("핫스팟", "Hotspot"))])
            StylePreviewSection(title: T("블루투스", "Bluetooth"), initial: settings.btStyle, preview: preview,
                                items: [("bt-airpods", "AirPods"), ("bt-low", T("배터리 낮은 마우스", "Low-Battery Mouse")),
                                        ("bt-nobattery", T("배터리 정보 없음", "No Battery Info"))])
            StylePreviewSection(title: T("집중 모드", "Focus"), initial: settings.focusStyle, preview: preview,
                                items: [("focus-on", T("집중 모드 켜짐", "Focus On")), ("focus-off", T("집중 모드 꺼짐", "Focus Off"))])
            StylePreviewSection(title: T("배터리", "Battery"), initial: settings.batteryStyle, preview: preview,
                                items: [("charger", T("충전기 연결", "Charger Connected")), ("low", T("배터리 부족", "Low Battery")), ("full", T("완충", "Full"))])
            // 형태가 정해진 알림
            testSection(T("컴팩트로만 표시", "Compact Only"),
                           [("hud-volume", T("음량 HUD", "Volume HUD")), ("hud-brightness", T("화면 밝기 HUD", "Display Brightness HUD")),
                            ("hud-keyboard", T("키보드 밝기 HUD", "Keyboard Brightness HUD")), ("download", T("다운로드", "Download")),
                            ("airdrop-send", T("에어드랍 보내기", "AirDrop Send")), ("recording", T("화면 녹화", "Screen Recording")),
                            ("call-active", T("통화 중", "On a Call")), ("lock", T("잠금화면 (5초)", "Lock Screen (5s)")),
                            ("ai-usage", T("AI 사용량", "AI Usage")), ("agent-done", T("Claude Code 작업 완료", "Claude Code Finished"))],
                           note: T("통화 중: 가짜 통화로 음소거·끊기를 눌러 볼 수 있고 30초 뒤 끝납니다. 잠금화면: 실제로 잠그지 않고 자물쇠·위젯을 5초 보여 줍니다.",
                                   "On a Call: a fake call where you can try Mute and End; it ends after 30 seconds. Lock Screen: shows the padlock and widget for 5 seconds without locking."))
            testSection(T("상세로만 표시", "Detailed Only"),
                           [("call-incoming", T("수신 전화", "Incoming Call")), ("offline", T("네트워크 끊김", "Network Lost")),
                            ("airdrop-receive", T("에어드랍 받기", "AirDrop Receive")), ("screenshot", T("스크린샷", "Screenshot")),
                            ("timer-done", T("타이머 종료", "Timer Done")), ("calendar", T("일정 알림", "Event Alert"))],
                           note: T("수신 전화: 가짜 전화로 받기·거절을 눌러 볼 수 있고 30초 동안 조작이 없으면 끝납니다.",
                                   "Incoming Call: a fake call where you can try Accept and Decline; it ends after 30 seconds without interaction."))
        }
        .settingsForm()
    }

    private func testSection(_ title: String, _ items: [(id: String, label: String)], note: String? = nil) -> some View {
        Section(title) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                ForEach(items, id: \.id) { item in
                    Button(item.label) { preview(item.id) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: - 정보

    private var about: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Dynamic MacNotch").font(.title.bold())
            Text(T("버전 ", "Version ") + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")).foregroundStyle(.secondary)
            Text(T("Apple Silicon(M1 이상) · macOS 14 Sonoma 이상", "Apple Silicon (M1 or later) · macOS 14 Sonoma or later")).font(.caption).foregroundStyle(.secondary)
            Link("github.com/tjehddnr2864-hue/Dynamic-MacNotch", destination: URL(string: "https://github.com/tjehddnr2864-hue/Dynamic-MacNotch")!)
                .font(.caption)
            Text(T("애드혹 서명(공증되지 않음)", "Ad-hoc signed (not notarized)")).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
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

private extension View {
    /// 유리 배경이 비치도록 폼 자체 배경을 지운다.
    func settingsForm() -> some View {
        formStyle(.grouped).scrollContentBackground(.hidden)
    }
}

/// 폴더 경로 설정: 현재 경로, '선택…'(폴더 고르기), '기본값'.
/// 화면 녹화·다운로드가 끝난 뒤 노치의 Finder 바로가기가 이 폴더를 연다.
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

/// 컴팩트·상세를 고를 수 있는 알림 묶음의 미리보기. 고른 형태는 이 미리보기에만 쓰이고 실제 설정은 그대로다.
private struct StylePreviewSection: View {
    var title: String
    var preview: (String) -> Void
    var items: [(id: String, label: String)]
    private let styleState: State<AlertStyle>

    init(title: String, initial: AlertStyle, preview: @escaping (String) -> Void, items: [(id: String, label: String)]) {
        self.title = title
        self.preview = preview
        self.items = items
        styleState = State(initialValue: initial)
    }

    var body: some View {
        Section {
            Picker(T("표시 형태", "Style"), selection: styleState.projectedValue) {
                ForEach(AlertStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                ForEach(items, id: \.id) { item in
                    Button(item.label) { preview(item.id + "@" + styleState.wrappedValue.rawValue) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Text(T("컴팩트·상세 선택", "Compact or Detailed")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 사이드바·카드 아이콘. SF Symbols에는 블루투스 로고가 없어 직접 그린다.
private struct SettingsIcon: View {
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

/// Claude Code · Codex 작업 완료 알림 설정. '연결'을 눌러야만 각 설정 파일에 훅을 넣는다.
private struct AgentSettingsPage: View {
    @ObservedObject var settings: AppSettings
    var preview: (String) -> Void
    private let refresh = State(initialValue: 0)
    private let errorState = State(initialValue: String?.none)

    var body: some View {
        let _ = refresh.wrappedValue   // 연결·해제 뒤 상태를 다시 읽는다
        Form {
            Section {
                Toggle(T("작업이 끝나면 노치에 알림 (누르면 그 앱 열기)", "Alert in the notch when a task finishes (click to open that app)"),
                       isOn: $settings.agentAlerts)
            } header: { Text(T("표시", "Show")) }
            Section {
                ForEach(AgentSource.allCases) { source in
                    let installed = AgentHooks.isInstalled(source)
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(installed ? T("연결됨", "Connected") : T("연결 안 됨", "Not connected"))
                                .foregroundStyle(installed ? .green : .secondary)
                            Button(installed ? T("연결 해제", "Disconnect") : T("연결", "Connect")) {
                                do {
                                    try installed ? AgentHooks.uninstall(source) : AgentHooks.install(source)
                                    errorState.wrappedValue = nil
                                } catch {
                                    errorState.wrappedValue = error.localizedDescription
                                }
                                refresh.wrappedValue += 1
                            }
                        }
                    } label: {
                        Label(source.name, systemImage: source.symbol)
                    }
                }
                if let error = errorState.wrappedValue {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: { Text(T("세부 설정", "Details")) } footer: {
                Text(T("연결하면 Claude Code는 ~/.claude/settings.json에 '작업 완료(Stop)' 훅을, Codex는 ~/.codex/config.toml의 notify에 이 앱을 넣습니다. Codex에 이미 notify가 있으면 그 명령도 그대로 이어서 실행되고, 연결 해제 시 원래대로 돌려놓습니다. 처음 바꾸기 전 원본은 .dynamicmacnotch.bak으로 남깁니다. 새로 시작한 Claude Code·Codex 세션부터 적용됩니다.",
                       "Connecting adds a Stop hook to ~/.claude/settings.json for Claude Code, and sets notify in ~/.codex/config.toml for Codex. If Codex already has a notify command, it still runs, and disconnecting restores it. The original file is kept as .dynamicmacnotch.bak before the first change. Applies to new Claude Code and Codex sessions."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(T("미리보기", "Preview")) {
                HStack {
                    Button(T("작업 완료 알림", "Finished Alert")) { preview("agent-done") }
                    Spacer(minLength: 0)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
