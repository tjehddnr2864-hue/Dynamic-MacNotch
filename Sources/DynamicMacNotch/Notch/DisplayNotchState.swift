import SwiftUI
import Combine

/// 디스플레이 하나의 노치 크기·상태. 상태는 액티비티 센터와 확장 여부에서 계산된다 (가이드라인 3장).
/// 디스플레이끼리 같아야 하는 값은 SharedNotchState에 있다.
final class DisplayNotchState: ObservableObject {
    let center: ActivityCenter
    let shared: SharedNotchState
    let settings = AppSettings.shared

    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published var hasPhysicalNotch = true
    @Published private(set) var isExpanded = false
    @Published var expandedPage: ExpandedPage = .home
    /// 홈의 카메라 거울을 켰는지 (켜면 노치가 더 커져 화면을 크게 보여 줌)
    @Published var cameraOn = false
    /// 음악 팝업 아래에 음량 줄을 펼쳤는지 (출력 기기 아이콘을 길게 눌러 토글)
    @Published private(set) var mediaVolumeShown = false
    /// 음량 줄이 더하는 높이
    static let mediaVolumeRowHeight: CGFloat = 26
    @Published var isHovering = false
    /// Mission Control 동안 노치를 숨긴 상태 (양쪽이 줄어들며 사라진다)
    @Published var missionControlHidden = false
    /// 길게누르기 진행도 (0...1). 누르는 동안 노치가 최대 6% 부풀어 오른다.
    @Published var pressProgress: CGFloat = 0
    /// 포스터치 stage 1 압력 (0...1).
    @Published var forcePressure: CGFloat = 0
    @Published var stretch = CGSize(width: 1, height: 1)
    @Published var shakeTrigger: CGFloat = 0
    /// 현재 홈 옵션. 마지막으로 본 옵션을 기억하고 모든 디스플레이가 공유한다.
    private(set) var homeOption: HomeOption {
        get { shared.homeOption }
        set { shared.homeOption = newValue }
    }

    private func saveHomeOption() { shared.saveHomeOption() }

    // MARK: - 홈 페이지 목록 (설정 → 상호작용 → 홈 기능)

    /// 보이는 홈 페이지 (설정한 순서, 끈 기능·홈에서 가린 트레이는 빠짐)
    var homePages: [HomeOption] {
        settings.homeOrder.compactMap(HomeOption.init(key:)).filter(settings.homeEnabled)
    }

    /// 지금 페이지가 꺼졌거나 가려졌으면 보이는 첫 페이지로 (파일을 끄는 중의 트레이는 예외)
    func ensureValidHome() {
        guard !isFileDragging else { return }
        let pages = homePages
        if !pages.contains(homeOption), let first = pages.first {
            homeOption = first
            saveHomeOption()
        }
    }
    /// 페이지 전환 방향 (true = 다음 페이지가 오른쪽에서 들어옴).
    @Published private(set) var pageForward = true
    /// 파일을 든 채 노치로 가져와 확장된 상태 (가이드라인 5.2).
    @Published private(set) var isFileDragging = false
    /// 두 손가락 스와이프 중 콘텐츠가 손가락을 따라가는 오프셋.
    @Published var swipeOffset: CGFloat = 0

    private var cancellables = Set<AnyCancellable>()

    init(center: ActivityCenter, shared: SharedNotchState) {
        self.center = center
        self.shared = shared
        shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 다른 페이지로 넘기면 카메라 끔
        shared.$homeOption
            .sink { [weak self] option in
                if option != .camera, self?.cameraOn == true { self?.cameraOn = false }
            }
            .store(in: &cancellables)
        // 액티비티 변화도 뷰 갱신을 일으키도록 전달한다.
        center.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 바뀐 뒤의 값을 보고 교체 애니메이션을 정한다
        center.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateCompactSwap() }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 홈 기능을 끄거나 순서를 바꾸면 지금 페이지가 남아 있는지 확인
        settings.$homeOrder.map { _ in () }
            .merge(with: settings.$homeDisabled.map { _ in () }, settings.$trayMode.map { _ in () }, settings.$chatEnabled.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.ensureValidHome() }
            .store(in: &cancellables)
    }

    // MARK: - 이 디스플레이에 보일 것 (가이드라인 3.6)

    /// 이 디스플레이의 상황. NotchHub가 정한다. 디스플레이가 하나면 모든 알림이 이곳에 온다.
    var context = DisplayContext(uuid: "", main: "", enabled: [""])

    /// 이 디스플레이에 뜨는 일회성 알림
    var visibleTransient: NotchActivity? {
        guard let t = center.transient, settings.displayRules.alertReaches(t, context) else { return nil }
        return t
    }

    /// 이 디스플레이의 상시 표시 항목 (우선순위 순)
    var visiblePersistent: [NotchActivity] {
        let kinds = settings.displayRules.persistentKinds(context, active: center.persistentKinds)
        return center.orderedPersistent.filter { kinds.contains($0.kind) }
    }

    var topPersistent: NotchActivity? {
        center.persistentHidden ? nil : visiblePersistent.first
    }

    /// 노치에 표시할 주 액티비티. 잠금 상태에서는 자물쇠만 보인다.
    var displayed: NotchActivity? {
        center.lockActivity ?? visibleTransient ?? topPersistent
    }

    // MARK: - 상태

    /// 액티비티만 보고 정한 상태 (교체 애니메이션 반영 전)
    private var baseState: NotchState {
        if isExpanded { return .expanded }
        guard let a = displayed else { return .idle }
        if center.showingDetail, center.transient?.id == a.id { return .detail }
        return .compact
    }

    var state: NotchState {
        let s = baseState
        // 컴팩트끼리 다른 항목으로 바뀌는 순간(예: 음악 → 블루투스)에는 먼저 노치 안으로 들어갔다가 나온다.
        if s == .compact, let shown = shownCompactKind, let kind = displayed?.kind, kind != shown {
            return .idle
        }
        return s
    }

    // MARK: - 컴팩트 교체 애니메이션 (들어갔다 나오기)

    /// 지금 노치에 그려진 컴팩트 항목의 종류. 새 항목과 다르면 교체 중(들어가는 중)이다.
    private var shownCompactKind: ActivityKind?
    private var swapWork: DispatchWorkItem?
    /// 들어가는 시간 (나오는 쪽은 openSpring)
    static let retractDuration: TimeInterval = 0.24

    var isRetracting: Bool {
        baseState == .compact && shownCompactKind != nil && displayed?.kind != shownCompactKind
    }

    /// 상태가 바뀔 때 노치 도형에 쓸 애니메이션
    var stateAnimation: Animation {
        if isRetracting { return reduceMotion ? .easeInOut(duration: 0.12) : .spring(duration: Self.retractDuration, bounce: 0) }
        return animationOverride ?? (state == .idle ? closeSpring : openSpring)
    }

    /// 상시 표시 우선순위를 바꾼 뒤(설정에서 5초 동안 더 바뀌지 않으면) 지금 보이는 항목을 새 순서로 다시 맞춘다.
    /// 교체 애니메이션 대기 중이던 항목·이전 항목 기억을 버리고, 현재 우선순위가 가장 높은 항목으로 갱신한다.
    func resyncPersistentOrder() {
        swapWork?.cancel()
        swapWork = nil
        shownCompactKind = baseState == .compact ? displayed?.kind : nil
        withAnimation(openSpring) { objectWillChange.send() }
    }

    /// 액티비티가 바뀐 뒤 호출: 컴팩트 → 다른 컴팩트면 잠깐 들어갔다가 새 항목으로 나온다.
    /// 상세 알림·확장 팝업이 끼면 기존처럼 바로 바뀐다.
    private func updateCompactSwap() {
        guard baseState == .compact, let kind = displayed?.kind else {
            swapWork?.cancel()
            swapWork = nil
            shownCompactKind = nil
            return
        }
        if shownCompactKind == nil || reduceMotion {
            shownCompactKind = kind
            return
        }
        guard kind != shownCompactKind, swapWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.swapWork = nil
            withAnimation(self.openSpring) {
                self.shownCompactKind = self.displayed?.kind
                self.objectWillChange.send()
            }
        }
        swapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retractDuration, execute: work)
    }

    /// 확장 상태에서 노치 바깥 아래에 따로 표시하는 페이지 점 영역 높이.
    static let dotsAreaHeight: CGFloat = 30
    /// 답변 완료 알림을 눌렀을 때: 채팅 페이지를 연다
    func openChat() {
        if isExpanded {
            selectHomeOption(.chat)
        } else {
            homeOption = .chat
            saveHomeOption()
            expand(page: .home)
        }
    }

    // MARK: - 애니메이션

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 모든 팝업 애니메이션은 확장 시간(0.42초)으로 통일한다. 길이가 정해진 스프링이라 닫힐 때도 같은 시간에 끝난다.
    static let popupDuration: TimeInterval = 0.42

    var openSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(duration: Self.popupDuration, bounce: 0.2)
    }

    var closeSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(duration: Self.popupDuration, bounce: 0.08)
    }

    var valueSpring: Animation {
        .interactiveSpring(response: 0.25, dampingFraction: 0.85)
    }

    // MARK: - 동작

    /// 확장은 한 번에 한 디스플레이만. 열기 직전에 불린다.
    var willExpand: (() -> Void)?

    func expand(page: ExpandedPage) {
        guard !isExpanded else { return }
        willExpand?()
        if page == .home { ensureValidHome() }
        expandedPage = page
        mediaVolumeShown = false
        if !reduceMotion {
            // 스쿼시 & 스트레치: 진행 방향으로 잠깐 늘었다가 스프링으로 복귀.
            stretch = CGSize(width: 1.03, height: 0.97)
        }
        withAnimation(openSpring) {
            isExpanded = true
            pressProgress = 0
            forcePressure = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                self.stretch = CGSize(width: 1, height: 1)
            }
        }
    }

    /// 음악 앨범아트 하나를 상태와 무관하게 계속 그리며, 상태별 위치·크기만 바꾼다 (도형 왼쪽 위 기준).
    /// 도형과 같은 스프링으로 움직이므로 항상 도형 안에서 커지고 줄어든다.
    var mediaArtRect: CGRect? {
        guard center.lockActivity == nil else { return nil }
        let n = notchSize
        switch state {
        case .expanded:
            // 상시 항목 팝업에서 다른 항목을 보는 동안에도 음악이 그 묶음에 있으면 남겨 두고 옆으로 비켜 둔다 (mediaArtPageShift)
            guard expandedPage == .activity(.media) || (showsPersistentDots && persistentPages.contains(.media)) else { return nil }
            // MediaPage: 좌우 여백(위쪽 모서리 + 22), 위 여백 6 + 4
            return CGRect(x: topRadius + 22, y: n.height + 10, width: 50, height: 50)
        case .detail:
            guard let a = displayed, a.kind == .media, a.artwork != nil else { return nil }
            // DetailActivityView: 좌 35, 노치 아래 남은 높이(58 - 10)의 가운데
            return CGRect(x: 35, y: n.height + 6, width: 36, height: 36)
        case .compact:
            guard let a = displayed, a.kind == .media, a.artwork != nil else { return nil }
            let s = min(19, n.height - 11)
            return CGRect(x: 4 + (a.wing - s) / 2, y: (n.height - s) / 2, width: s, height: s)
        case .idle:
            return nil
        }
    }

    /// 상시 항목 팝업에서 음악 앨범아트가 있어야 할 곳 (페이지 한 칸 = 1).
    /// 음악 페이지면 0, 음악보다 뒤 페이지를 보면 -1(왼쪽으로 밀려남), 앞 페이지를 보면 +1(오른쪽에서 대기).
    /// 페이지를 넘길 때 다른 내용과 같은 애니메이션으로 함께 밀려나고 들어온다.
    var mediaArtPageShift: CGFloat {
        guard state == .expanded, case .activity(let kind) = expandedPage, kind != .media,
              let current = persistentPages.firstIndex(of: kind), let media = persistentPages.firstIndex(of: .media) else { return 0 }
        return current > media ? -1 : 1
    }

    // 도형이 줄어드는 중인지 (줄어들 때 새로 나타나는 내용은 바깥으로 퍼지지 않고 제자리에서 나타나야 한다)
    private var lastArea: CGFloat = 0
    private var shrinkingFlag = false

    func isShrinking(to size: CGSize) -> Bool {
        let area = size.width * size.height
        if area != lastArea {
            shrinkingFlag = area < lastArea
            lastArea = area
        }
        return shrinkingFlag
    }

    /// 지금 진행 중인 전환에 쓸 애니메이션 (뷰의 크기·상태 애니메이션이 이 값을 따른다).
    private(set) var animationOverride: Animation?

    /// 음악 팝업은 닫힐 때 조금 더 천천히 (0.55초)
    var mediaCollapseSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(duration: 0.55, bounce: 0.06)
    }

    /// 음량 줄을 펼치거나 접는다: 팝업이 한 줄만큼 아래로 늘어나며 줄이 나타난다.
    func toggleMediaVolume() {
        guard isExpanded, expandedPage == .activity(.media) else { return }
        withAnimation(openSpring) { mediaVolumeShown.toggle() }
    }

    func collapse() {
        guard isExpanded else { return }
        let animation = expandedPage == .activity(.media) ? mediaCollapseSpring : closeSpring
        animationOverride = animation
        withAnimation(animation) {
            isExpanded = false
            cameraOn = false   // 노치를 닫으면 카메라 끔
        }
        MemoryTrim.soon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.animationOverride = nil }
    }

    func beginPress(duration: TimeInterval) {
        withAnimation(.easeOut(duration: duration)) { pressProgress = 1 }
    }

    func endPress() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            pressProgress = 0
            forcePressure = 0
        }
    }

    func setForcePressure(_ value: CGFloat) {
        withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.9)) {
            forcePressure = value
        }
    }

    func shake() {
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 0.5)) { shakeTrigger += 1 }
    }

    func selectHomeOption(_ option: HomeOption) {
        guard option != homeOption || expandedPage != .home else { return }
        let pages = homePages
        pageForward = (pages.firstIndex(of: option) ?? 0) >= (pages.firstIndex(of: homeOption) ?? 0)
        withAnimation(openSpring) {
            homeOption = option
            expandedPage = .home
            swipeOffset = 0
        }
        saveHomeOption()
    }

    // MARK: - 상시 표시 항목 넘기기
    // 상시 표시 항목을 길게 눌러 연 팝업에서는 홈처럼 아래 점·두 손가락 좌우로 다른 상시 항목을 넘겨 본다.
    // (닫으면 노치는 언제나 우선순위가 가장 높은 항목을 보여 준다 — ActivityCenter.displayed)

    /// 길게 눌러 열 화면: 보이는 알림·상시 항목의 팝업, 아무것도 없으면 홈.
    /// AI 사용량만 상시 표시 중이면 홈의 AI 사용량 페이지로 연다 (홈 점·스와이프로 카메라·타이머 등).
    /// 다른 상시 항목과 함께 있으면 상시 항목 모음 팝업으로 연다 (점으로 넘겨 봄).
    func longPressPage(for activity: NotchActivity?) -> ExpandedPage {
        guard let a = activity else { return .home }
        let pages = Self.monitorKinds.contains(a.kind) ? monitorPages(for: a.kind) : [a.kind]
        // 실시간 모니터링 한 페이지만 열고 다른 상시 항목이 없으면 홈의 그 페이지로 연다 (홈 점으로 다른 페이지도 넘겨 봄)
        if pages.count == 1, center.transient?.id != a.id, persistentPages.count <= 1,
           let home = pages[0] == .aiUsage ? HomeOption.usage : (pages[0] == .resource ? HomeOption.resource : nil),
           homePages.contains(home) {
            homeOption = home
            saveHomeOption()
            return .home
        }
        return .activity(pages.first ?? a.kind)
    }

    static let monitorKinds: Set<ActivityKind> = [.aiUsage, .resource, .monitor]

    /// 실시간 모니터링 항목을 꾹 눌렀을 때 넘겨 볼 페이지. '노치에 보이는 항목을 따름'이면 그 항목에 맞춘다.
    func monitorPages(for kind: ActivityKind) -> [ActivityKind] {
        let options = MonitorLayout.availableExpands(aiOn: settings.monitorAIOn, resourceOn: settings.monitorResourceOn)
        let expand = options.contains(settings.monitorExpand) ? settings.monitorExpand : .follow
        switch expand {
        case .ai: return [.aiUsage]
        case .resource: return [.resource]
        case .both: return [.aiUsage, .resource]
        case .follow: return kind == .monitor ? [.aiUsage, .resource] : [kind]
        }
    }

    /// 넘겨 볼 수 있는 상시 표시 항목 (우선순위 순). 실시간 모니터링 항목은 확장 화면 페이지로 펼친다.
    var persistentPages: [ActivityKind] {
        var pages: [ActivityKind] = []
        for kind in visiblePersistent.map(\.kind) {
            for page in Self.monitorKinds.contains(kind) ? monitorPages(for: kind) : [kind] where !pages.contains(page) {
                pages.append(page)
            }
        }
        return pages
    }

    /// 자원 사용량 확장 화면이 보이는지 (보이는 동안만 네 지표를 읽는다)
    var showsResourcePage: Bool {
        isExpanded && (expandedPage == .activity(.resource) || (expandedPage == .home && homeOption == .resource))
    }

    /// 지금 상시 항목 팝업을 보고 있고, 넘길 항목이 둘 이상인지
    var showsPersistentDots: Bool {
        guard state == .expanded, case .activity(let kind) = expandedPage else { return false }
        let pages = persistentPages
        return pages.count > 1 && pages.contains(kind)
    }

    func selectPersistentPage(_ kind: ActivityKind) {
        guard case .activity(let current) = expandedPage, current != kind else { return }
        let pages = persistentPages
        pageForward = (pages.firstIndex(of: kind) ?? 0) >= (pages.firstIndex(of: current) ?? 0)
        withAnimation(openSpring) {
            expandedPage = .activity(kind)
            mediaVolumeShown = false
            swipeOffset = 0
        }
    }

    /// 스와이프 중 손가락을 따라 콘텐츠를 옮긴다. 양 끝에서는 고무줄처럼 덜 움직인다.
    func dragPage(by contentDX: CGFloat) {
        if expandedPage != .home {
            if expandedPage == .activity(.media) {
                // 음악 팝업은 좌우 스와이프로 곡 이동 → 살짝만 따라 움직임
                swipeOffset = contentDX * 0.2
            } else if showsPersistentDots, case .activity(let kind) = expandedPage {
                let pages = persistentPages
                let atEdge = (contentDX > 0 && pages.first == kind) || (contentDX < 0 && pages.last == kind)
                swipeOffset = atEdge ? contentDX * 0.15 : contentDX * 0.45
            } else {
                swipeOffset = 0
            }
            return
        }
        let pages = homePages
        let atEdge = (contentDX > 0 && pages.first == homeOption) || (contentDX < 0 && pages.last == homeOption)
        swipeOffset = atEdge ? contentDX * 0.15 : contentDX * 0.45
    }

    func switchExpandedPage(forward: Bool) {
        guard isExpanded else { return }
        if expandedPage == .activity(.media), let onMediaSwipe = shared.onMediaSwipe {
            onMediaSwipe(forward)
            cancelDrag()
            return
        }
        if expandedPage != .home {
            // 상시 항목 팝업: 다른 상시 항목으로 넘긴다 (홈과는 따로)
            if showsPersistentDots, case .activity(let kind) = expandedPage {
                let pages = persistentPages
                if let i = pages.firstIndex(of: kind), pages.indices.contains(i + (forward ? 1 : -1)) {
                    selectPersistentPage(pages[i + (forward ? 1 : -1)])
                    return
                }
            }
            cancelDrag()
            return
        }
        let pages = homePages
        if let i = pages.firstIndex(of: homeOption), pages.indices.contains(i + (forward ? 1 : -1)) {
            selectHomeOption(pages[i + (forward ? 1 : -1)])
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { swipeOffset = 0 }
        }
    }

    /// 파일 드래그가 노치에 가까워지면 트레이 페이지로 자동 확장한다.
    func beginFileDrag() {
        guard !isFileDragging, acceptsFileDrag else { return }
        let bothOn = settings.trayMode != .off && settings.chatEnabled
        // 이미 그 화면이 열려 있으면 그대로 두고, 아니면 설정한 화면으로 연다
        if !(bothOn && isExpanded && expandedPage == .home && (homeOption == .tray || homeOption == .chat)) {
            if bothOn {
                homeOption = settings.fileDragPage == .chat ? .chat : .tray
            } else {
                homeOption = settings.chatEnabled ? .chat : .tray
            }
        }
        expandedPage = .home
        withAnimation(openSpring) { isFileDragging = true }
        if !isExpanded { expand(page: .home) }
        Haptics.perform()
    }

    /// 파일을 끌어와도 열 화면이 있는지
    var acceptsFileDrag: Bool { settings.trayMode != .off || settings.chatEnabled }

    /// 파일을 든 동안 옮겨 갈 다른 화면. 파일을 들고 있고 트레이·AI 채팅이 모두 켜져 있을 때만 있다.
    var fileDragOtherPage: HomeOption? {
        guard isFileDragging, settings.trayMode != .off, settings.chatEnabled, expandedPage == .home else { return nil }
        switch homeOption {
        case .tray: return .chat
        case .chat: return .tray
        default: return nil
        }
    }

    /// 다른 화면이 기본 노치 순서에서 왼쪽에 있으면 막대도 왼쪽에 둔다
    var fileDragBarOnLeft: Bool {
        guard let other = fileDragOtherPage else { return false }
        let order = settings.homeOrder
        return (order.firstIndex(of: other.key) ?? .max) < (order.firstIndex(of: homeOption.key) ?? .max)
    }

    /// 막대와 노치 사이 간격 (아래 페이지 점과 노치 사이와 같다)
    static let fileDragBarGap: CGFloat = 8
    /// 막대 바탕의 굵기 (아래 페이지 점의 바탕과 같다)
    static let fileDragBarThickness: CGFloat = 18
    /// 막대를 받는 폭 (간격 + 막대 + 바깥 여유)
    static let fileDragBarZone: CGFloat = fileDragBarGap + fileDragBarThickness + 8

    /// 막대의 받는 영역. x는 노치 중심 기준, y는 화면 위에서부터.
    /// 노치 위쪽 모서리가 바깥으로 벌어져 있어, 실제 몸통은 도형 폭보다 topRadius만큼씩 좁다.
    var fileDragBarRect: CGRect? {
        guard fileDragOtherPage != nil else { return nil }
        let size = targetSize
        let edge = size.width / 2 - topRadius
        return CGRect(x: fileDragBarOnLeft ? -edge - Self.fileDragBarZone : edge,
                      y: notchSize.height, width: Self.fileDragBarZone, height: size.height - notchSize.height + Self.fileDragBarGap)
    }

    private var lastFileDragSwitch = Date.distantPast

    /// 막대에 커서가 닿으면 다른 화면으로 옮긴다 (막대가 옮겨 가는 동안 되돌아오지 않게 잠깐 쉰다)
    func switchFileDragPage() {
        guard let other = fileDragOtherPage, Date().timeIntervalSince(lastFileDragSwitch) > 0.45 else { return }
        lastFileDragSwitch = Date()
        pageForward = !fileDragBarOnLeft
        withAnimation(openSpring) {
            homeOption = other
            swipeOffset = 0
        }
        Haptics.perform()
    }

    func endFileDrag(dropped: Bool) {
        guard isFileDragging else { return }
        withAnimation(openSpring) { isFileDragging = false }
        if !dropped { collapse() }
    }

    func cancelDrag() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { swipeOffset = 0 }
    }
}
