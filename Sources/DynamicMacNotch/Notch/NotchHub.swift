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
    /// 노치를 켠 디스플레이 전부 (주 디스플레이가 먼저). 비는 일이 없다.
    private(set) var displays: [DisplayNotch] = []
    /// 지금 조작의 대상이 되는 노치: 펼쳐진 것, 없으면 맨 앞
    var current: DisplayNotch { displays.first { $0.vm.isExpanded } ?? displays[0] }

    /// 어느 디스플레이에서든 확장이 접힐 때
    let collapsed = PassthroughSubject<Void, Never>()
    /// 어느 디스플레이에서든 호버하거나 확장할 때
    let interacted = PassthroughSubject<Void, Never>()

    var anyExpanded: Bool { displays.contains { $0.vm.isExpanded } }
    var anyHovering: Bool { displays.contains { $0.vm.isHovering } }
    var anyFileDragging: Bool { displays.contains { $0.vm.isFileDragging } }

    private let settings = AppSettings.shared
    private let rootView: (DisplayNotchState) -> NotchRootView
    private let menuProvider: () -> NSMenu
    private let clickHandler: (DisplayNotchState, NotchActivity?, Bool) -> Void
    private var cancellables = Set<AnyCancellable>()
    private var observers: [String: Set<AnyCancellable>] = [:]
    private var syncWork: DispatchWorkItem?

    private var isLocked: () -> Bool = { false }
    private var missionControlActive = false
    private var panelsHidden = false
    private var lockPanelShown = false

    init(center: ActivityCenter, shared: SharedNotchState,
         rootView: @escaping (DisplayNotchState) -> NotchRootView,
         menuProvider: @escaping () -> NSMenu,
         clickHandler: @escaping (DisplayNotchState, NotchActivity?, Bool) -> Void) {
        self.center = center
        self.shared = shared
        self.rootView = rootView
        self.menuProvider = menuProvider
        self.clickHandler = clickHandler
        sync()
        // 화면 구성 변화는 한 번에 여러 번 오므로 모아서 처리한다. 설정 변화는 바로.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)
        settings.$notchDisplays.map { _ in () }
            .merge(with: settings.$displayContent.map { _ in () })
            .dropFirst(2)
            .sink { [weak self] in DispatchQueue.main.async { self?.sync() } }
            .store(in: &cancellables)
    }

    // MARK: - 디스플레이 맞추기

    private func scheduleSync() {
        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sync() }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// 켜야 할 디스플레이와 지금 패널을 비교해 차이만 반영한다
    func sync() {
        var wanted = wantedUUIDs()
        // 연결된 화면이 하나도 없을 때(덮개를 닫고 모니터도 없음)는 지금 패널을 그대로 둔다
        if wanted.isEmpty {
            guard displays.isEmpty else { return }
            wanted = [""]
        }
        guard wanted != displays.map(\.uuid) else { return }
        let wasLockDisplay = lockDisplay
        for display in displays where !wanted.contains(display.uuid) {
            observers[display.uuid] = nil
            display.vm.collapse()
            display.tearDown()
        }
        displays = wanted.map { uuid in displays.first { $0.uuid == uuid } ?? makeDisplay(uuid) }
        center.paused = anyHovering
        // 잠금 중에 잠금 노치가 있던 디스플레이가 사라지면 새 주 디스플레이로 옮긴다
        if lockPanelShown, lockDisplay !== wasLockDisplay { lockDisplay?.setLockPanelVisible(true) }
    }

    private func wantedUUIDs() -> [String] {
        // 선택한 디스플레이가 없으면 Displays.screen이 고른 화면으로 대신한다 (설정 값은 그대로 두어 다시 연결되면 돌아온다)
        let connected = Displays.screens.compactMap(Displays.uuid(of:))
        let selection = settings.notchDisplays
        let wanted = Displays.enabledUUIDs(selection: selection, content: settings.displayContent, connected: connected)
        if selection == "all" || selection == "main" { return wanted }
        if let uuid = Displays.uuid(selection: selection), connected.contains(uuid) { return wanted }
        return Displays.screen(for: selection).flatMap(Displays.uuid(of:)).map { [$0] } ?? wanted
    }

    private func makeDisplay(_ uuid: String) -> DisplayNotch {
        let state = DisplayNotchState(center: center, shared: shared)
        let display = DisplayNotch(uuid: uuid, vm: state, rootView: rootView(state), menuProvider: menuProvider, clickHandler: clickHandler)
        display.isLocked = isLocked
        observe(display)
        // 숨겨야 하는 동안 생긴 노치는 숨긴 채로 시작한다
        if panelsHidden { display.setMainPanelHidden(true, animated: false) }
        if missionControlActive { display.setMissionControlActive(true) }
        return display
    }

    private func observe(_ display: DisplayNotch) {
        var bag = Set<AnyCancellable>()
        // 호버는 디스플레이별로 모은다: 하나라도 호버 중이면 알림 시간을 멈춘다
        display.onHoverChanged = { [weak self] in
            guard let self else { return }
            self.center.paused = self.anyHovering
        }
        // 확장은 한 번에 하나: 다른 디스플레이에서 열면 먼저 열려 있던 쪽을 접는다
        display.vm.willExpand = { [weak self, weak display] in
            self?.displays.filter { $0 !== display && $0.vm.isExpanded }.forEach { $0.vm.collapse() }
        }
        display.vm.$isExpanded
            .dropFirst()
            .sink { [weak self] expanded in
                if expanded { self?.interacted.send() } else { self?.collapsed.send() }
            }
            .store(in: &bag)
        display.vm.$isHovering
            .filter { $0 }
            .sink { [weak self] _ in self?.interacted.send() }
            .store(in: &bag)
        observers[display.uuid] = bag
    }

    // MARK: - 모든 디스플레이에

    func collapseAll() { displays.forEach { $0.vm.collapse() } }

    func shake() { displays.forEach { $0.vm.shake() } }

    func releaseKeyFocus() { displays.forEach { $0.releaseKeyFocus() } }

    func resyncPersistentOrder() { displays.forEach { $0.vm.resyncPersistentOrder() } }

    func setIsLocked(_ isLocked: @escaping () -> Bool) {
        self.isLocked = isLocked
        displays.forEach { $0.isLocked = isLocked }
    }

    /// Mission Control은 모든 디스플레이에 함께 뜨므로 노치도 함께 숨기고 함께 돌아온다
    func setMissionControlActive(_ active: Bool) {
        missionControlActive = active
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
        panelsHidden = hidden
        displays.forEach { $0.setMainPanelHidden(hidden, animated: animated) }
    }

    // MARK: - 잠금화면 (창은 주 디스플레이에 하나만 쓴다)

    /// 주 디스플레이가 "노치 없음"이거나 선택되지 않았으면 잠금 노치도 없다
    private var lockDisplay: DisplayNotch? {
        guard let main = Displays.screens.first.flatMap(Displays.uuid(of:)) else { return displays.first }
        return displays.first { $0.uuid == main }
    }

    func setLockPanelVisible(_ visible: Bool) {
        lockPanelShown = visible
        lockDisplay?.setLockPanelVisible(visible)
    }

    func prepareLockPanel() { lockDisplay?.prepareLockPanel() }

    var lockPanelReady: Bool { lockDisplay?.lockPanelReady ?? false }

    func forceRefresh() { displays.forEach { $0.forceRefresh() } }
}
