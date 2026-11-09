import AppKit
import SwiftUI
import Combine

/// 앱의 조립 지점: 기능 객체를 만들고 서로 연결한다.
/// 노치 조작은 AppDelegate+NotchActions, 메뉴는 AppDelegate+Menu, 개발용 명령은 AppDelegate+Dev에 있다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    let center = ActivityCenter()
    lazy var timer = TimerController(center: center)
    lazy var battery = BatteryMonitor(center: center)
    lazy var network = NetworkMonitor(center: center)
    lazy var bluetooth = BluetoothMonitor(center: center)
    lazy var focus = FocusMonitor(center: center)
    lazy var hud = HUDMonitor(center: center)
    lazy var media = MediaController(center: center)
    lazy var downloads = DownloadMonitor(center: center)
    lazy var tray = TrayStore(center: center)
    lazy var screenshot = ScreenshotMonitor(center: center)
    lazy var recording = RecordingMonitor(center: center)
    lazy var call = CallMonitor(center: center)
    lazy var usage = UsageStore(center: center)
    lazy var monitor = MonitorCoordinator(center: center, usage: usage)
    lazy var calendar = CalendarController(center: center)
    let memo = MemoStore()
    let chat = ChatStore()
    lazy var featurePreview = FeaturePreview(
        center: center, battery: battery, media: media, call: call, focus: focus, timer: timer, screenshot: screenshot,
        lockScreen: { [weak self] in self?.lockScreen })

    /// 앱이 뜨는 즉시 만들어진다 (applicationDidFinishLaunching 맨 앞)
    var hub: NotchHub!
    var vm: DisplayNotchState { notch?.vm ?? hub.current.vm }
    var notch: DisplayNotch? {
        #if DEV
        if let hub, hub.displays.indices.contains(devDisplay) { return hub.displays[devDisplay] }
        #endif
        return hub?.current
    }
    #if DEV
    /// 개발용: 시험 명령이 향할 디스플레이 번호 (음수면 평소처럼)
    var devDisplay = -1
    /// 개발용: 칸 그리기 방식 비교 (monitortest)
    var monitorTest: AnyCancellable?
    #endif
    var lockScreen: LockScreenManager?
    let missionControl = MissionControlMonitor()
    var statusItem: NSStatusItem?
    private var agentObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeHub()
        startLockScreen()
        observeNotch()
        startMonitors()
        observeSettings()
        usage.start()
        monitor.start()
        agentObserver = AgentNotify.observe(center: center)
        startUpdaterAndMemoryGuard()
        missionControl.onChange = { [weak self] active in self?.hub.setMissionControlActive(active) }
        missionControl.start()
        observeChat()
        if !settings.onboardingDone {
            showPermissions(onboarding: true)
        }
        listenToHelper()
    }

    // MARK: - 조립

    private func makeHub() {
        let features = NotchFeatures(media: media, screenshot: screenshot, recording: recording, tray: tray, calendar: calendar,
                                     call: call, usage: usage, memo: memo, chat: chat)
        let shared = SharedNotchState()
        shared.verticalScrollHandler = { [weak self] dy in self?.timer.handleScroll(fingerDY: dy) ?? false }
        shared.verticalScrollEnded = { [weak self] in self?.timer.endScroll() }
        // 음악 팝업·작은 노치에서 두 손가락 좌우: 다음/이전 곡 (넘길 수 없는 미디어면 아무 일도 하지 않음)
        shared.onMediaSwipe = { [weak self] forward in
            guard let self, self.media.canSkip(forward ? 1 : -1) else { return }
            forward ? self.media.next() : self.media.previousTrack()
            Haptics.perform()
        }
        shared.longPressShouldExpand = { [weak self] activity in self?.longPress(activity) ?? true }
        shared.allowsPressFeedback = { [weak self] activity in self?.hasLongPressAction(activity) ?? true }
        shared.onDetailSwipeUp = { [weak self] in
            guard let self else { return }
            if self.center.transient?.kind == .call { self.call.minimizeIncoming() } else { self.center.dismissTransient() }
        }
        let timer = self.timer
        hub = NotchHub(
            center: center,
            shared: shared,
            rootView: { [weak self] state in
                NotchRootView(vm: state, timer: timer, features: features) { self?.showSettings() }
            },
            menuProvider: { [weak self] in self?.makeMenu() ?? NSMenu() },
            clickHandler: { [weak self] state, activity, leftSide in self?.handleClick(activity, leftSide: leftSide, on: state) }
        )
        timer.onShake = { [weak hub] in hub?.shake() }
    }

    private func startLockScreen() {
        let manager = LockScreenManager(center: center, hub: hub, media: media)
        manager.start()
        lockScreen = manager
        hub.setIsLocked { [weak manager] in manager?.isLocked ?? false }
    }

    private func observeNotch() {
        timer.$editingUnit
            .removeDuplicates()
            .filter { $0 == nil }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.hub.releaseKeyFocus() } }
            .store(in: &cancellables)
        hub.collapsed
            .sink { [weak self] in
                self?.timer.endEditing()
                self?.tray.releaseViewCaches()
                DispatchQueue.main.async { self?.hub.releaseKeyFocus() }
            }
            .store(in: &cancellables)
        center.objectWillChange.merge(with: recording.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.collapseIfActivityGone() }
            .store(in: &cancellables)
        // 재생 테스트 중 노치에 커서를 올리거나 열면 '조작'으로 보고 자동 중지 시간을 늘린다
        hub.interacted
            .sink { [weak self] in self?.media.noteTestInteraction() }
            .store(in: &cancellables)
    }

    private func startMonitors() {
        battery.start()
        network.start()
        bluetooth.start()
        focus.start()
        hud.start()
        media.start()
        downloads.onAirDropReceived = { [weak self] urls in
            // 에어드랍·트레이를 끄면 받은 파일을 트레이에 넣지 않는다
            guard let self, self.settings.trayMode != .off else { return }
            self.tray.airDropReceived(urls)
        }
        downloads.start()
        screenshot.start()
        screenshot.onCapture = { [weak self] in self?.recording.screenshotTaken() }
        recording.start()
        call.start()
    }

    private func observeSettings() {
        // 상시 표시 우선순위: 바뀌면 바로 교체 애니메이션을 시작하고(순서만 바뀌면 상시 항목은 그대로라 신호가 없었음),
        // 5초 동안 더 바뀌지 않으면 새 순서로 다시 맞춘다 (중간 상태가 남아 표시가 꼬이지 않게)
        settings.$persistentOrder
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.center.objectWillChange.send() }
            .store(in: &cancellables)
        settings.$persistentOrder
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.center.objectWillChange.send()   // 정렬·상시 표시·AI 사용량 가림 여부 다시 계산
                self.hub.resyncPersistentOrder()
            }
            .store(in: &cancellables)
        // 일정 상시 표시 켜기·끄기 (일정 기능이 켜져 있을 때만 다시 읽음)
        settings.$calendarPinned
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.settings.isHomeFeatureOn("calendar") else { return }
                self.calendar.reload()
            }
            .store(in: &cancellables)
        // 기본 노치 기능 켜기·끄기: 끈 기능은 백그라운드 작업까지 멈춘다
        settings.$homeDisabled
            .receive(on: RunLoop.main)
            .sink { [weak self] disabled in self?.applyHomeFeatures(disabled) }
            .store(in: &cancellables)
        settings.$showStatusItem
            .sink { [weak self] show in self?.setStatusItem(visible: show) }
            .store(in: &cancellables)
    }

    private func startUpdaterAndMemoryGuard() {
        // 자동 업데이트: 상태는 노치 상세 알림으로
        Updater.shared.onUpdated = { [weak self] version in self?.center.post(Updater.doneActivity(version: version)) }
        Updater.shared.notify = { [weak self] title, subtitle, success in
            self?.center.post(NotchActivity(
                kind: .demo, presentation: .detail, duration: 4,
                symbol: success ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill",
                tint: success ? .blue : .orange, value: .none, title: title, subtitle: subtitle))
        }
        Updater.shared.announceIfUpdated()
        // 메모리 지킴이: 기준을 넘으면 캐시를 비우고, 그래도 넘으면 쉬는 동안 조용히 다시 시작
        MemoryGuard.shared.isIdle = { [weak self] in self?.isIdleForRelaunch() ?? false }
        MemoryGuard.shared.releaseCaches = {
            TrayItemView.clearIconCache()
            DownloadMonitor.clearIconCache()
            URLCache.shared.removeAllCachedResponses()
            ResourceSampler.shared.compact()
        }
        MemoryGuard.shared.relaunch = { [weak self] in self?.restart() }
        MemoryGuard.shared.start()
        Updater.shared.start()
    }

    /// AI 채팅: 대화가 있으면 큰 노치, 입력·생각 중이면 작은 노치. 페이지를 닫은 동안 답변이 끝나면 알린다.
    private func observeChat() {
        chat.objectWillChange
            .receive(on: RunLoop.main)
            .compactMap { [weak self] in self?.chat.isLarge }
            .removeDuplicates()
            .sink { [weak self] large in self?.hub.shared.chatLarge = large }
            .store(in: &cancellables)
        chat.onFinishedInBackground = { [weak self] failure, title in
            self?.center.post(ChatStore.finishedActivity(failure: failure, title: title))
        }
    }

    /// 설정 도우미와 주고받는 채널
    private func listenToHelper() {
        DistributedNotificationCenter.default().addObserver(forName: AppSettings.changedNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            self?.settings.reload()
        }
        // 분산 알림은 보낸 쪽을 확인할 수 없으므로 배포 빌드는 해가 없는 명령(정해진 미리보기, 다시 시작)만 받는다.
        // 나머지는 개발 빌드(-DDEV)에서만.
        DistributedNotificationCenter.default().addObserver(
            forName: Helper.commandNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let command = note.object as? String else { return }
            switch command {
            case let c where c.hasPrefix("preview:"):
                // 허용 목록(PreviewID)에 있는 미리보기만 실행. "@compact"/"@detail"이 붙으면 그 형태로.
                let parts = c.dropFirst(8).split(separator: "@", maxSplits: 1).map(String.init)
                if let first = parts.first, let id = PreviewID(rawValue: first) {
                    self.featurePreview.run(id, style: parts.count > 1 ? AlertStyle(rawValue: parts[1]) : nil)
                }
            case "restart": self.restart()
            case "chatscleared": self.chat.storedChatsCleared()   // 파일이 실제로 지워졌을 때만 메모리에서 지운다
            default:
                #if DEV
                self.handleDevCommand(command)
                #endif
            }
        }
    }

    private func applyHomeFeatures(_ disabled: [String]) {
        if disabled.contains("calendar") { calendar.stop() } else { calendar.start() }
        if disabled.contains("timer"), timer.isActive { timer.cancel() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        media.stop()
        memo.saveNow()   // 쓰던 메모 (다시 시작·메모리 정리 재시작 포함)
    }


    // MARK: - 메모리 지킴이

    /// 자동 재시작해도 사용자가 알아채지 못할 때: 노치가 닫혀 있고 알림·조작·진행 중인 작업이 없음.
    /// (음악 재생은 다른 앱에서 계속되므로 막지 않는다)
    private func isIdleForRelaunch() -> Bool {
        let busyKinds: Set<ActivityKind> = [.download, .airdrop, .recording, .call, .demo, .timer]
        return !hub.anyExpanded && !hub.anyHovering && !hub.anyFileDragging
            && center.transient == nil && center.persistentKinds.isDisjoint(with: busyKinds)
            && recording.startedAt == nil && call.state == .idle && !timer.isActive && !chat.isStreaming && chat.draft.isEmpty && chat.pending.isEmpty && chat.attaching == 0
            && lockScreen?.isLocked != true && helperProcess?.isRunning != true && !FilePicker.isRunning
            && !media.testActive && !call.previewActive && screenshot.shot == nil
    }

    // MARK: - 설정·권한 창 (별도 도우미 프로세스)

    private var helperProcess: Process?

    func showSettings() { openHelper("settings") }

    func showPermissions(onboarding: Bool) { openHelper(onboarding ? "onboarding" : "permissions") }

    /// 설정 창은 같은 실행 파일을 도우미 모드로 띄워 연다. 창을 닫으면 도우미가 끝나며 메모리가 모두 반환된다.
    /// 이미 떠 있으면 새로 띄우지 않고 그 창을 앞으로 가져온다.
    private func openHelper(_ mode: String) {
        hub.collapseAll()
        if let p = helperProcess, p.isRunning {
            DistributedNotificationCenter.default().postNotificationName(Helper.helperNotification, object: mode,
                                                                         userInfo: nil, deliverImmediately: true)
            return
        }
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--helper=" + mode]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.helperProcess = nil
                self?.settings.reload()   // 혹시 놓친 변경이 있으면 마지막으로 한 번 더 읽는다
            }
        }
        do {
            try p.run()
            helperProcess = p
        } catch {
            NSLog("DynamicMacNotch: failed to launch settings helper: \(error)")
        }
    }

    func closeHelper() {
        DistributedNotificationCenter.default().postNotificationName(Helper.helperNotification, object: "close",
                                                                     userInfo: nil, deliverImmediately: true)
    }
}
