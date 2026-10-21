import SwiftUI
import Combine

enum NotchState: Int, Equatable {
    case idle, compact, detail, expanded
}

/// 홈의 네 가지 옵션. 한 번에 하나씩 표시하고 점·스와이프로 넘긴다.
enum HomeOption: Int, CaseIterable {
    case camera, timer, calendar, tray

    var title: String {
        switch self {
        case .camera: return T("카메라", "Camera")
        case .timer: return T("타이머", "Timer")
        case .calendar: return T("오늘 일정", "Today")
        case .tray: return T("에어드랍 · 트레이", "AirDrop · Tray")
        }
    }

    var symbol: String {
        switch self {
        case .camera: return "camera.fill"
        case .timer: return "timer"
        case .calendar: return "calendar"
        case .tray: return "tray.and.arrow.down.fill"
        }
    }
}

enum ExpandedPage: Equatable {
    case home
    case activity(ActivityKind)
}

/// 노치 크기·상태의 단일 원천. 상태는 액티비티 센터와 확장 여부에서 계산된다 (가이드라인 3장).
final class NotchViewModel: ObservableObject {
    let center: ActivityCenter
    let settings = AppSettings.shared

    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published var hasPhysicalNotch = true
    @Published private(set) var isExpanded = false
    @Published var expandedPage: ExpandedPage = .home
    /// 상세 알림 위에서 두 손가락으로 위로 올렸을 때 (전화 수신 카드는 접기, 그 밖은 닫기)
    var onDetailSwipeUp: (() -> Void)?
    /// 음악 팝업 아래에 음량 줄을 펼쳤는지 (출력 기기 아이콘을 길게 눌러 토글)
    @Published private(set) var mediaVolumeShown = false
    /// 음량 줄이 더하는 높이
    static let mediaVolumeRowHeight: CGFloat = 26
    @Published var isHovering = false
    /// 길게누르기 진행도 (0...1). 누르는 동안 노치가 최대 6% 부풀어 오른다.
    @Published var pressProgress: CGFloat = 0
    /// 포스터치 stage 1 압력 (0...1).
    @Published var forcePressure: CGFloat = 0
    @Published var stretch = CGSize(width: 1, height: 1)
    @Published var shakeTrigger: CGFloat = 0
    /// 현재 홈 옵션. 마지막으로 본 옵션을 기억한다.
    @Published private(set) var homeOption: HomeOption =
        HomeOption(rawValue: UserDefaults.standard.integer(forKey: "homeOption")) ?? .camera
    /// 페이지 전환 방향 (true = 다음 페이지가 오른쪽에서 들어옴).
    @Published private(set) var pageForward = true
    /// 파일을 든 채 노치로 가져와 확장된 상태 (가이드라인 5.2).
    @Published private(set) var isFileDragging = false
    /// 두 손가락 스와이프 중 콘텐츠가 손가락을 따라가는 오프셋.
    @Published var swipeOffset: CGFloat = 0

    private var cancellables = Set<AnyCancellable>()

    init(center: ActivityCenter) {
        self.center = center
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
    }

    // MARK: - 상태

    /// 액티비티만 보고 정한 상태 (교체 애니메이션 반영 전)
    private var baseState: NotchState {
        if isExpanded { return .expanded }
        guard let a = center.displayed else { return .idle }
        if center.showingDetail, center.transient?.id == a.id { return .detail }
        return .compact
    }

    var state: NotchState {
        let s = baseState
        // 컴팩트끼리 다른 항목으로 바뀌는 순간(예: 음악 → 블루투스)에는 먼저 노치 안으로 들어갔다가 나온다.
        if s == .compact, let shown = shownCompactKind, let kind = center.displayed?.kind, kind != shown {
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
        baseState == .compact && shownCompactKind != nil && center.displayed?.kind != shownCompactKind
    }

    /// 상태가 바뀔 때 노치 도형에 쓸 애니메이션
    var stateAnimation: Animation {
        if isRetracting { return reduceMotion ? .easeInOut(duration: 0.12) : .spring(duration: Self.retractDuration, bounce: 0) }
        return animationOverride ?? (state == .idle ? closeSpring : openSpring)
    }

    /// 액티비티가 바뀐 뒤 호출: 컴팩트 → 다른 컴팩트면 잠깐 들어갔다가 새 항목으로 나온다.
    /// 상세 알림·확장 팝업이 끼면 기존처럼 바로 바뀐다.
    private func updateCompactSwap() {
        guard baseState == .compact, let kind = center.displayed?.kind else {
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
                self.shownCompactKind = self.center.displayed?.kind
                self.objectWillChange.send()
            }
        }
        swapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retractDuration, execute: work)
    }

    /// 목표 크기 (애니메이션 전 최종값).
    var targetSize: CGSize {
        let n = notchSize
        switch state {
        case .idle:
            let bump: CGFloat = settings.hoverPreview && isHovering ? 1 : 0
            return CGSize(width: n.width + 14 * bump, height: n.height + 4 * bump)
        case .compact:
            let wing = NotchActivity.wing(for: center.displayed)
            return CGSize(width: n.width + wing * 2, height: n.height)
        case .detail:
            // 상세(확장) 알림: 컴팩트보다 좌우·아래로 조금 더 커진다. 스크린샷처럼 전용 높이가 있으면 넓게.
            if let extra = center.displayed?.detailHeight {
                return CGSize(width: max(n.width + 190, 390), height: n.height + extra)
            }
            return CGSize(width: max(n.width + 150, 330), height: n.height + 58)
        case .expanded:
            switch expandedPage {
            case .home:
                return expandedBaseSize
            case .activity(let kind):
                return popupSize(for: kind)
            }
        }
    }

    /// 상시 표시 항목을 길게 눌렀을 때 뜨는 독립 팝업 크기.
    func popupSize(for kind: ActivityKind) -> CGSize {
        let n = notchSize
        switch kind {
        case .media:
            // 참고 이미지: 노치보다 좌우로 넓고, 앨범아트·진행 바·조작 버튼 3줄
            return CGSize(width: max(n.width + 125, 300) + 2 * topRadius,
                          height: n.height + 152 + (mediaVolumeShown ? Self.mediaVolumeRowHeight : 0))
        case .timer:
            return CGSize(width: max(n.width + 60, 240) + 2 * topRadius, height: n.height + 120)
        case .call:
            // 음악 팝업과 같은 폭, 한 줄(상대·버튼)
            return CGSize(width: max(n.width + 125, 300) + 2 * topRadius, height: n.height + 84)
        case .download:
            // 음악 팝업과 같은 폭, 두 줄(아이콘·파일명 / 진행 바)에 맞춘 높이
            return CGSize(width: max(n.width + 125, 300) + 2 * topRadius, height: n.height + 104)
        case .recording:
            return CGSize(width: max(n.width + 60, 240) + 2 * topRadius, height: n.height + 110)
        default:
            // 알림 확장 카드(아이콘 | 이름·설명 | 값): 아래 여백을 좌우 여백(28pt)과 같게
            return CGSize(width: max(n.width + 60, 240) + 2 * topRadius, height: n.height + 84)
        }
    }

    /// 기본 확장(길게누르기): 좌우로는 넓어지지 않고 노치 폭 그대로 아래로만 커진다.
    /// 도형의 위쪽 오목 모서리 폭(topRadius)만큼 양옆을 더해야 몸통이 노치 폭과 일치한다.
    var expandedBaseSize: CGSize {
        // 기본 팝업(홈): 노치 폭보다 좌우 8% 넓게, 아래로 확장
        CGSize(width: (notchSize.width * 1.08).rounded() + 2 * topRadius, height: ((notchSize.height + 154) * 0.9).rounded())
    }

    /// 확장 상태에서 노치 바깥 아래에 따로 표시하는 페이지 점 영역 높이.
    static let dotsAreaHeight: CGFloat = 30

    /// 마우스가 반응해야 하는 영역 (확장 시 바깥 점 포함).
    var interactiveSize: CGSize {
        var size = targetSize
        if state == .expanded, expandedPage == .home { size.height += Self.dotsAreaHeight }
        return size
    }

    /// 누르기 피드백까지 반영한 실제 표시 크기.
    var displaySize: CGSize {
        let size = targetSize
        guard state != .expanded else { return size }
        let p = 1 + 0.06 * max(pressProgress, forcePressure)
        return CGSize(width: size.width * p, height: size.height * p)
    }

    /// 위쪽(디스플레이 안으로 들어가는) 오목 모서리. 확장될수록 아래쪽 모서리와 함께 더 크게 휜다.
    var topRadius: CGFloat {
        switch state {
        case .idle, .compact: return 8
        case .detail: return 13
        case .expanded: return 16
        }
    }

    var bottomRadius: CGFloat {
        switch state {
        case .idle: return 10
        case .compact: return 12
        case .detail: return 30
        case .expanded: return 40
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

    func expand(page: ExpandedPage) {
        guard !isExpanded else { return }
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
            guard expandedPage == .activity(.media) else { return nil }
            // MediaPage: 좌우 여백(위쪽 모서리 + 22), 위 여백 6 + 4
            return CGRect(x: topRadius + 22, y: n.height + 10, width: 50, height: 50)
        case .detail:
            guard let a = center.displayed, a.kind == .media, a.artwork != nil else { return nil }
            // DetailActivityView: 좌 35, 노치 아래 남은 높이(58 - 10)의 가운데
            return CGRect(x: 35, y: n.height + 6, width: 36, height: 36)
        case .compact:
            guard let a = center.displayed, a.kind == .media, a.artwork != nil else { return nil }
            let s = min(19, n.height - 11)
            return CGRect(x: 4 + (a.wing - s) / 2, y: (n.height - s) / 2, width: s, height: s)
        case .idle:
            return nil
        }
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
        withAnimation(animation) { isExpanded = false }
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
        pageForward = option.rawValue >= homeOption.rawValue
        withAnimation(openSpring) {
            homeOption = option
            expandedPage = .home
            swipeOffset = 0
        }
        UserDefaults.standard.set(option.rawValue, forKey: "homeOption")
    }

    /// 스와이프 중 손가락을 따라 콘텐츠를 옮긴다. 양 끝에서는 고무줄처럼 덜 움직인다.
    func dragPage(by contentDX: CGFloat) {
        if expandedPage != .home {
            // 음악 팝업은 좌우 스와이프로 곡 이동 → 살짝만 따라 움직임
            swipeOffset = expandedPage == .activity(.media) ? contentDX * 0.2 : 0
            return
        }
        let atEdge = (contentDX > 0 && homeOption == .camera) || (contentDX < 0 && homeOption == .tray)
        swipeOffset = atEdge ? contentDX * 0.15 : contentDX * 0.45
    }

    /// 확장 상태의 세로 스크롤을 먼저 가져갈 처리기 (타이머 시·분·초 조절). 처리하면 true.
    var verticalScrollHandler: ((CGFloat) -> Bool)?
    var verticalScrollEnded: (() -> Void)?

    /// 음악 제어 페이지에서 좌우 스와이프 = 이전/다음 곡 (가이드라인 5.7)
    var onMediaSwipe: ((Bool) -> Void)?

    func switchExpandedPage(forward: Bool) {
        guard isExpanded else { return }
        if expandedPage == .activity(.media), let onMediaSwipe {
            onMediaSwipe(forward)
            cancelDrag()
            return
        }
        if expandedPage != .home {
            // 상시 항목 팝업은 홈과 독립: 넘기지 않는다.
            cancelDrag()
            return
        }
        let next = homeOption.rawValue + (forward ? 1 : -1)
        if let option = HomeOption(rawValue: next) {
            selectHomeOption(option)
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { swipeOffset = 0 }
        }
    }

    /// 파일 드래그가 노치에 가까워지면 트레이 페이지로 자동 확장한다.
    func beginFileDrag() {
        guard !isFileDragging else { return }
        homeOption = .tray
        expandedPage = .home
        withAnimation(openSpring) { isFileDragging = true }
        if !isExpanded { expand(page: .home) }
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
