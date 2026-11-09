import AppKit
import SwiftUI
import Combine

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
        // 무엇을 보일지 정하는 설정이 바뀌면 지금 보이는 항목을 다시 맞춘다
        settings.$displayContent.map { _ in () }
            .merge(with: settings.$displayFallbackToMain.map { _ in () }, settings.$alertScope.map { _ in () },
                   settings.$criticalAlertsEnabled.map { _ in () }, settings.$criticalAlertAdded.map { _ in () },
                   settings.$criticalAlertRemoved.map { _ in () })
            .dropFirst(6)
            .sink { [weak self] in DispatchQueue.main.async { self?.resyncPersistentOrder() } }
            .store(in: &cancellables)
        // 자원 측정: 보이는 항목·설정이 바뀌거나 화면이 꺼지고 켜지면 다시 계산
        center.objectWillChange.map { _ in () }
            .merge(with: settings.objectWillChange.map { _ in () })
            .sink { [weak self] in self?.scheduleResourceDemand() }
            .store(in: &cancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.willSleepNotification, true),
                               (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.didWakeNotification, false)] {
            workspace.publisher(for: name)
                .sink { [weak self] _ in
                    self?.screensAsleep = asleep
                    self?.scheduleResourceDemand()
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - 자원 측정 수요

    private var screensAsleep = false
    private var demandOwners = Set<String>()
    private var demandWork: DispatchWorkItem?

    private func scheduleResourceDemand() {
        demandWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateResourceDemand() }
        demandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// 디스플레이마다 노치 칸에 실제로 보이는 자원 지표만 측정한다.
    /// 일회성 알림이 잠깐 가린 것은 보이는 것으로 본다 (끊었다 이으면 더 비싸다).
    /// 측정을 요청한 적이 없으면 측정 객체를 만들지 않는다.
    private func updateResourceDemand() {
        let paused = panelsHidden || missionControlActive || screensAsleep || center.lockActivity != nil
        let resource = settings.resourceSlots, both = settings.bothSlots
        var current = Set<String>()
        for display in displays {
            current.insert(display.uuid)
            var metrics = Set<MonitorMetric>()
            if !paused, let top = display.vm.topPersistent {
                if top.kind == .resource { metrics = [resource.left, resource.right] }
                if top.kind == .monitor { metrics = [both.left, both.right] }
            }
            metrics.formIntersection(MonitorMetric.resourceMetrics)
            guard !metrics.isEmpty || demandOwners.contains(display.uuid) else { continue }
            ResourceSampler.shared.setDemand(.compact(display.uuid), metrics)
            if metrics.isEmpty { demandOwners.remove(display.uuid) } else { demandOwners.insert(display.uuid) }
        }
        for gone in demandOwners.subtracting(current) {
            ResourceSampler.shared.setDemand(.compact(gone), [])
            demandOwners.remove(gone)
        }
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
        guard wanted != displays.map(\.uuid) else {
            updateContexts()
            return
        }
        let wasLockDisplay = lockDisplay
        for display in displays where !wanted.contains(display.uuid) {
            observers[display.uuid] = nil
            display.vm.collapse()
            display.tearDown()
        }
        displays = wanted.map { uuid in displays.first { $0.uuid == uuid } ?? makeDisplay(uuid) }
        updateContexts()
        center.paused = anyHovering
        // 잠금 중에 잠금 노치가 있던 디스플레이가 사라지면 새 주 디스플레이로 옮긴다
        if lockPanelShown, lockDisplay !== wasLockDisplay { lockDisplay?.setLockPanelVisible(true) }
    }

    /// 각 노치에 자기 상황을 알려 주고, 바뀌었으면 보이는 항목을 다시 맞춘다
    private func updateContexts() {
        let enabled = displays.map(\.uuid)
        let main = Displays.screens.first.flatMap(Displays.uuid(of:)) ?? enabled[0]
        for display in displays {
            let context = DisplayContext(uuid: display.uuid, main: main, enabled: enabled)
            guard context != display.vm.context else { continue }
            display.vm.context = context
            display.vm.resyncPersistentOrder()
        }
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
        scheduleResourceDemand()
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
        scheduleResourceDemand()
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
