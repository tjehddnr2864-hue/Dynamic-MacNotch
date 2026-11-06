import AppKit
import SwiftUI
import Combine

/// 모든 디스플레이가 함께 쓰는 노치 상태. 알림과 저장소는 ActivityCenter 등에 이미 하나씩 있고,
/// 여기에는 화면 쪽 상태 중 어느 디스플레이에서 봐도 같아야 하는 것만 둔다.
final class SharedNotchState: ObservableObject {
    /// 마지막으로 본 홈 페이지. 어느 디스플레이에서 열든 여기서 시작한다.
    @Published var homeOption: HomeOption = SharedNotchState.savedHomeOption()
    /// AI 채팅: 대화를 보여 주는 중인지 (입력만 있거나 생각 중이면 작은 노치)
    @Published var chatLarge = false
    /// 입력 칸이 여러 줄로 늘어난 높이
    @Published var chatInputExtra: CGFloat = 0

    /// 길게누르기 전에 묻는다: 이 활동을 확장 화면으로 열지(true), 앱이 따로 처리했는지(false).
    var longPressShouldExpand: ((NotchActivity?) -> Bool)?
    /// 누르고 있을 때 커지는 반응을 보일지 (상세 알림처럼 길게누르기가 없는 경우 false → 클릭만 반응)
    var allowsPressFeedback: ((NotchActivity?) -> Bool)?
    /// 상세 알림 위에서 두 손가락으로 위로 올렸을 때 (전화 수신 카드는 접기, 그 밖은 닫기)
    var onDetailSwipeUp: (() -> Void)?
    /// 확장 상태의 세로 스크롤을 먼저 가져갈 처리기 (타이머 시·분·초 조절). 처리하면 true.
    var verticalScrollHandler: ((CGFloat) -> Bool)?
    var verticalScrollEnded: (() -> Void)?
    /// 음악 제어 페이지에서 좌우 스와이프 = 이전/다음 곡 (가이드라인 5.7)
    var onMediaSwipe: ((Bool) -> Void)?

    private static let homeKey = "homeOptionKey"

    /// 마지막으로 본 홈 페이지 (이름으로 저장. 예전 번호 저장값은 한 번 옮겨 읽는다)
    private static func savedHomeOption() -> HomeOption {
        let d = UserDefaults.standard
        if let key = d.string(forKey: homeKey), let o = HomeOption(key: key) { return o }
        if d.object(forKey: "homeOption") != nil, let o = HomeOption(rawValue: d.integer(forKey: "homeOption")) { return o }
        return .camera
    }

    func saveHomeOption() {
        UserDefaults.standard.set(homeOption.key, forKey: Self.homeKey)
    }
}

/// 디스플레이별 노치(DisplayNotch)를 묶는다. 앱의 나머지 부분은 패널을 직접 만지지 않고 이곳을 거친다.
final class NotchHub {
    let center: ActivityCenter
    let shared: SharedNotchState
    /// 지금 조작의 대상이 되는 노치
    let current: DisplayNotch
    /// 노치를 켠 디스플레이 전부
    var displays: [DisplayNotch] { [current] }

    /// 어느 디스플레이에서든 확장이 접힐 때
    let collapsed = PassthroughSubject<Void, Never>()
    /// 어느 디스플레이에서든 호버하거나 확장할 때
    let interacted = PassthroughSubject<Void, Never>()

    var anyExpanded: Bool { displays.contains { $0.vm.isExpanded } }
    var anyHovering: Bool { displays.contains { $0.vm.isHovering } }
    var anyFileDragging: Bool { displays.contains { $0.vm.isFileDragging } }

    private var cancellables = Set<AnyCancellable>()

    init(center: ActivityCenter, shared: SharedNotchState,
         rootView: @escaping (DisplayNotchState) -> NotchRootView,
         menuProvider: @escaping () -> NSMenu,
         clickHandler: @escaping (DisplayNotchState, NotchActivity?, Bool) -> Void) {
        self.center = center
        self.shared = shared
        let state = DisplayNotchState(center: center, shared: shared)
        current = DisplayNotch(vm: state, rootView: rootView(state), menuProvider: menuProvider, clickHandler: clickHandler)
        observe(current)
    }

    private func observe(_ display: DisplayNotch) {
        // 호버는 디스플레이별로 모은다: 하나라도 호버 중이면 알림 시간을 멈춘다
        display.onHoverChanged = { [weak self] in
            guard let self else { return }
            self.center.paused = self.anyHovering
        }
        display.vm.$isExpanded
            .sink { [weak self] expanded in
                if expanded { self?.interacted.send() } else { self?.collapsed.send() }
            }
            .store(in: &cancellables)
        display.vm.$isHovering
            .filter { $0 }
            .sink { [weak self] _ in self?.interacted.send() }
            .store(in: &cancellables)
    }

    // MARK: - 모든 디스플레이에

    func collapseAll() { displays.forEach { $0.vm.collapse() } }

    func shake() { displays.forEach { $0.vm.shake() } }

    func releaseKeyFocus() { displays.forEach { $0.releaseKeyFocus() } }

    func resyncPersistentOrder() { displays.forEach { $0.vm.resyncPersistentOrder() } }

    func setIsLocked(_ isLocked: @escaping () -> Bool) { displays.forEach { $0.isLocked = isLocked } }

    /// Mission Control은 모든 디스플레이에 함께 뜨므로 노치도 함께 숨기고 함께 돌아온다
    func setMissionControlActive(_ active: Bool) {
        if active {
            center.hiddenFromScreen = true
            displays.forEach { $0.setMissionControlActive(true) }
            center.paused = false
        } else {
            displays.forEach { $0.setMissionControlActive(false) }
            center.hiddenFromScreen = false
            displays.forEach { $0.refreshHover() }
        }
    }

    func setMainPanelsHidden(_ hidden: Bool, animated: Bool) {
        displays.forEach { $0.setMainPanelHidden(hidden, animated: animated) }
    }

    // MARK: - 잠금화면 (창은 하나만 쓴다)

    func setLockPanelVisible(_ visible: Bool) { current.setLockPanelVisible(visible) }
    func prepareLockPanel() { current.prepareLockPanel() }
    var lockPanelReady: Bool { current.lockPanelReady }
    func forceRefresh() { displays.forEach { $0.forceRefresh() } }
}
