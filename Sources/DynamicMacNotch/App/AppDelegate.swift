import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let center = ActivityCenter()
    private lazy var timer = TimerController(center: center)
    private lazy var battery = BatteryMonitor(center: center)
    private lazy var network = NetworkMonitor(center: center)
    private lazy var bluetooth = BluetoothMonitor(center: center)
    private lazy var focus = FocusMonitor(center: center)
    private lazy var hud = HUDMonitor(center: center)
    private lazy var media = MediaController(center: center)
    private lazy var downloads = DownloadMonitor(center: center)
    private lazy var tray = TrayStore(center: center)
    private lazy var screenshot = ScreenshotMonitor(center: center)
    private lazy var recording = RecordingMonitor(center: center)
    private lazy var call = CallMonitor(center: center)
    private lazy var usage = UsageStore(center: center)
    private let memo = MemoStore()
    private let chat = ChatStore()
    private var agentObserver: NSObjectProtocol?
    private lazy var featurePreview = FeaturePreview(
        center: center, battery: battery, media: media, call: call, focus: focus, timer: timer, screenshot: screenshot,
        lockScreen: { [weak self] in self?.lockScreen })
    private var previewObservers = Set<AnyCancellable>()
    private lazy var calendar = CalendarController(center: center)

    /// 앱이 뜨는 즉시 만들어진다 (applicationDidFinishLaunching 맨 앞)
    private var hub: NotchHub!
    private var vm: DisplayNotchState { notch?.vm ?? hub.current.vm }
    private var notch: DisplayNotch? {
        #if DEV
        if let hub, hub.displays.indices.contains(devDisplay) { return hub.displays[devDisplay] }
        #endif
        return hub?.current
    }
    #if DEV
    /// 개발용: 시험 명령이 향할 디스플레이 번호 (음수면 평소처럼)
    private var devDisplay = -1
    #endif
    private var lockScreen: LockScreenManager?
    private let missionControl = MissionControlMonitor()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let hub = NotchHub(
            center: center,
            shared: shared,
            rootView: { [weak self] state in
                NotchRootView(vm: state, timer: timer, features: features) { self?.showSettings() }
            },
            menuProvider: { [weak self] in self?.makeMenu() ?? NSMenu() },
            clickHandler: { [weak self] state, activity, leftSide in self?.handleClick(activity, leftSide: leftSide, on: state) }
        )
        self.hub = hub
        timer.onShake = { [weak hub] in hub?.shake() }
        let manager = LockScreenManager(center: center, hub: hub, media: media)
        manager.setLockNotchVisible = { [weak hub] visible in hub?.setLockPanelVisible(visible) }
        manager.prepareLockNotch = { [weak hub] in hub?.prepareLockPanel() }
        manager.setMainNotchHidden = { [weak hub] hidden, animated in hub?.setMainPanelsHidden(hidden, animated: animated) }
        manager.lockNotchAvailable = { [weak hub] in hub?.lockPanelReady ?? false }
        manager.refreshNotch = { [weak hub] in hub?.forceRefresh() }
        manager.start()
        lockScreen = manager
        hub.setIsLocked { [weak manager] in manager?.isLocked ?? false }
        timer.$editingUnit
            .removeDuplicates()
            .filter { $0 == nil }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.hub.releaseKeyFocus() } }
            .store(in: &cancellables)
        hub.collapsed
            .sink { [weak self] in
                self?.timer.endEditing()
                DispatchQueue.main.async { self?.hub.releaseKeyFocus() }
            }
            .store(in: &cancellables)
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
        usage.start()
        agentObserver = AgentNotify.observe(center: center)

        settings.$showStatusItem
            .sink { [weak self] show in self?.setStatusItem(visible: show) }
            .store(in: &cancellables)

        // 자동 업데이트: 상태는 노치 상세 알림으로
        Updater.shared.onUpdated = { [weak self] version in self?.center.post(Updater.doneActivity(version: version)) }
        Updater.shared.notify = { [weak self] title, subtitle, success in
            self?.center.post(NotchActivity(
                kind: .demo, presentation: .detail, duration: 4,
                symbol: success ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill",
                tint: success ? .blue : .orange, value: .none, title: title, subtitle: subtitle))
        }
        Updater.shared.announceIfUpdated()
        // 메모리 지킴이: 70MB를 넘으면 캐시를 비우고, 그래도 넘으면 쉬는 동안 조용히 다시 시작
        MemoryGuard.shared.isIdle = { [weak self] in self?.isIdleForRelaunch() ?? false }
        MemoryGuard.shared.releaseCaches = {
            TrayItemView.clearIconCache()
            DownloadMonitor.clearIconCache()
            URLCache.shared.removeAllCachedResponses()
        }
        MemoryGuard.shared.relaunch = { [weak self] in self?.restart() }
        MemoryGuard.shared.start()
        center.objectWillChange.merge(with: recording.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.collapseIfActivityGone() }
            .store(in: &previewObservers)
        // 재생 테스트 중 노치에 커서를 올리거나 열면 '조작'으로 보고 자동 중지 시간을 늘린다
        hub.interacted
            .sink { [weak self] in self?.media.noteTestInteraction() }
            .store(in: &previewObservers)
        Updater.shared.start()
        missionControl.onChange = { [weak self] active in self?.hub.setMissionControlActive(active) }
        missionControl.start()
        // AI 채팅: 대화가 있으면 큰 노치, 입력·생각 중이면 작은 노치. 페이지를 닫은 동안 답변이 끝나면 알린다.
        chat.objectWillChange
            .receive(on: RunLoop.main)
            .compactMap { [weak self] in self?.chat.isLarge }
            .removeDuplicates()
            .sink { [weak shared] large in shared?.chatLarge = large }
            .store(in: &cancellables)
        chat.onFinishedInBackground = { [weak self] failure, title in
            self?.center.post(ChatStore.finishedActivity(failure: failure, title: title))
        }

        if !settings.onboardingDone {
            showPermissions(onboarding: true)
        }

        // 설정 도우미가 값을 바꾸면 다시 읽는다.
        DistributedNotificationCenter.default().addObserver(forName: AppSettings.changedNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            self?.settings.reload()
        }

        // 설정 도우미 → 본 앱 명령 채널. 분산 알림은 보낸 쪽을 확인할 수 없으므로
        // 배포 빌드는 해가 없는 명령(정해진 미리보기, 다시 시작)만 받는다. 나머지는 개발 빌드(-DDEV)에서만.
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


    #if DEV
    /// 개발용: `scripts/notchctl <명령>`으로 테스트 액티비티·화면을 띄운다 (개발 빌드에만 포함).
    private func handleDevCommand(_ command: String) {
            switch command {
            case "home": self.vm.expand(page: .home)
            case "collapse": self.vm.collapse()
            case "media": self.vm.expand(page: .activity(.media))
            case "shot": self.screenshot.debugPresentClipboard()
            case let c where c.hasPrefix("popup:"):
                if let kind = ActivityKind(rawValue: String(c.dropFirst(6))) { self.vm.expand(page: .activity(kind)) }
            case "settings": self.showSettings()
            case "permissions": self.showPermissions(onboarding: false)
            case "closewin": self.closeHelper()
            case "update": Updater.shared.check(userInitiated: true)   // 개발용: 지금 업데이트 확인
            case "longpress":   // 개발용: 길게누르기와 같은 판단
                if self.hub.shared.longPressShouldExpand?(self.center.displayed) ?? true {
                    self.vm.expand(page: self.vm.longPressPage(for: self.center.displayed))
                }
            case let c where c.hasPrefix("shotfile:"): self.screenshot.debugPresentFile(URL(fileURLWithPath: String(c.dropFirst(9))))
            case "shotdelete": self.screenshot.delete()
            case "memtest":   // 개발용: 기준을 1MB로 낮춰 지킴이 동작(캐시 비우기 → 쉬는 동안 재시작)을 시험
                MemoryGuard.testLimitMB = 1
                MemoryGuard.shared.debugCheckNow()
            case "skipnext": self.hub.shared.onMediaSwipe?(true)
            case "skipprev": self.hub.shared.onMediaSwipe?(false)
            case "recstop": self.recording.stop()   // 개발용: 녹화 정지(⌃⌘Esc)
            case "pick": FilePicker.choose(.tray) { self.tray.add($0) }   // 개발용: 트레이 파일 선택 창
            case "volrow": self.vm.toggleMediaVolume()   // 개발용: 음악 팝업 음량 줄 토글
            case "favtoggle": self.media.toggleFavorite()   // 개발용: 즐겨찾기 토글
            case let c where c.hasPrefix("trayadd:"):   // 개발용
                self.tray.add(String(c.dropFirst(8)).split(separator: "|").map { URL(fileURLWithPath: String($0)) })
            case "trayclear": self.tray.clear()
            case "hide": self.center.setPersistentHidden(true)
            case "unhide": self.center.setPersistentHidden(false)
            case "lock": self.lockScreen?.lock(preview: true)
            case "unlock": self.lockScreen?.unlock()
            case "lockfull": self.lockScreen?.openFull()
            case "saveron": self.lockScreen?.setScreenSaver(active: true)    // 개발용: 화면 보호기 시작/끝 흉내
            case "saveroff": self.lockScreen?.setScreenSaver(active: false)
            case "memolist": self.memo.toggleList()   // 개발용: 메모 목록 열기/닫기
            case let c where c.hasPrefix("devclick:"):   // 개발용: 노치 창에 클릭 보내기 (화면 좌표, 왼쪽 위 기준 "x,y")
                let xy = c.dropFirst(9).split(separator: ",").compactMap { Double($0) }
                if xy.count == 2, let panel = self.notch?.panel, let screen = panel.screen {
                    panel.ignoresMouseEvents = false   // 실제 커서가 노치 위에 없어도 받도록
                    let p = NSPoint(x: xy[0] - panel.frame.minX, y: screen.frame.maxY - xy[1] - panel.frame.minY)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            panel.sendEvent(e)
                        }
                    }
                }
            case let c where c.hasPrefix("vpnsim:"):   // 개발용: VPN 연결 흉내 (vpnsim:이름, vpnsim: 는 해제)
                NetworkMonitor.debugVPNName = String(c.dropFirst(7))
                self.network.debugEvaluate()
            case let c where c.hasPrefix("vpncountry:"):   // 개발용: 국가 조회 결과 지정 (신호는 보내지 않음, vpncountry: 는 조회 실패)
                NetworkMonitor.debugCountry = String(c.dropFirst(11))
            case let c where c.hasPrefix("devover:"):   // 개발용: 화면 좌표(왼쪽 위 기준 "x,y") 아래 내용이 스크롤되는지 파일로
                let xy = c.dropFirst(8).split(separator: ",").compactMap { Double($0) }
                if xy.count == 3 - 1, let panel = self.notch?.panel, let screen = panel.screen {
                    let p = NSPoint(x: xy[0] - panel.frame.minX, y: screen.frame.maxY - xy[1] - panel.frame.minY)
                    let line = "\(self.notch?.isScrollable(atWindowPoint: p) ?? false)\n"
                    try? line.write(toFile: NSTemporaryDirectory() + "dmn-over.txt", atomically: true, encoding: .utf8)
                }
            case let c where c.hasPrefix("devswipe:"):   // 개발용: 노치 창에 두 손가락 좌우 스크롤 (예: devswipe:-120 = 다음 페이지)
                if let dx = Double(c.dropFirst(9)), let panel = self.notch?.panel {
                    let center = CGPoint(x: panel.frame.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - panel.frame.maxY + 120)
                    let steps: [(Int64, Double)] = [(1, 0)] + Array(repeating: (2, dx / 6), count: 6) + [(4, 0)]
                    for (phase, delta) in steps {
                        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0,
                                               wheel2: Int32(delta), wheel3: 0) else { continue }
                        cg.location = center
                        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: delta)
                        if let e = NSEvent(cgEvent: cg) { panel.sendEvent(e) }
                    }
                }
            case let c where c.hasPrefix("devtype:"):   // 개발용: 이 앱에만 글자 입력
                if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                    tv.insertText(String(c.dropFirst(8)), replacementRange: tv.selectedRange())
                    break
                }
                for ch in String(c.dropFirst(8)) {
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                        var u = Array(String(ch).utf16)
                        e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
                        e?.postToPid(getpid())
                    }
                }
            case let c where c.hasPrefix("devscroll:"):   // 개발용: 노치 창 안 스크롤 (화면 좌표 "x,y,픽셀", 픽셀이 양수면 위 내용 보기)
                let v = c.dropFirst(10).split(separator: ",").compactMap { Double($0) }
                if v.count == 3, let panel = self.notch?.panel, let screen = panel.screen {
                    let p = NSPoint(x: v[0] - panel.frame.minX, y: screen.frame.maxY - v[1] - panel.frame.minY)
                    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(v[2]), wheel2: 0, wheel3: 0) else { break }
                    cg.location = CGPoint(x: v[0], y: v[1])
                    if let e = NSEvent(cgEvent: cg) { panel.contentView?.hitTest(p)?.scrollWheel(with: e) }
                }
            case let c where c.hasPrefix("devkey:"):   // 개발용: 이 앱에 키 입력 (가상 키 코드, 끝에 :shift 또는 :cmd, 예: devkey:36 = Enter, devkey:8:cmd = ⌘C)
                let parts = c.dropFirst(7).split(separator: ":")
                if let first = parts.first, let code = UInt16(first), let window = NSApp.keyWindow {
                    let chars = [UInt16(53): "\u{1b}", 8: "c", 9: "v", 0: "a"][code] ?? "\r"
                    let flags: NSEvent.ModifierFlags = parts.count < 2 ? [] : (parts[1] == "cmd" ? .command : .shift)
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                                    characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                }
            case "chat": self.vm.openChat()   // 개발용: AI 채팅 페이지 열기
            case let c where c.hasPrefix("chatsend:"):   // 개발용: 클릭 없이 질문 보내기
                self.chat.draft = String(c.dropFirst(9))
                self.chat.send()
            case "chatlist": self.chat.toggleList()   // 개발용: 채팅 목록 열기·닫기
            case let c where c.hasPrefix("chatattach:"):   // 개발용: 클릭 없이 파일 첨부
                self.chat.attach([URL(fileURLWithPath: String(c.dropFirst(11)))])
            case "dragbegin": self.vm.beginFileDrag()   // 개발용: 파일 끌기 시작
            case "dragswitch": self.vm.switchFileDragPage()   // 개발용: 막대에 닿은 것처럼
            case "dragend": self.vm.endFileDrag(dropped: false)   // 개발용: 파일 끌기 끝
            case "chatdelete": self.chat.delete(self.chat.currentID)   // 개발용: 지금 채팅 삭제
            case "chatpaste":   // 개발용: 시험용 클립보드에서 첨부
                if let board = ChatAnswerTextView.testPasteboard { _ = self.chat.attachFromPasteboard(board) }
            case "devfocusanswer":   // 개발용: 첫 답변 본문을 전체 선택
                func find(_ view: NSView) -> ChatAnswerTextView? {
                    if let tv = view as? ChatAnswerTextView { return tv }
                    for sub in view.subviews { if let f = find(sub) { return f } }
                    return nil
                }
                if let tv = self.notch?.panel.contentView.flatMap(find) {
                    tv.window?.makeFirstResponder(tv)
                    tv.selectAll(nil)
                }
            case let c where c.hasPrefix("devdisplay:"):   // 개발용: 이후 명령이 향할 디스플레이 (devdisplay:-1 = 평소처럼)
                self.devDisplay = Int(c.dropFirst(11)) ?? -1
            case "displaystate":   // 개발용: 노치가 어느 디스플레이에 있는지 기록
                let lines = ["selection=\(self.settings.notchDisplays) paused=\(self.center.paused)"]
                    + self.hub.displays.map { d in
                        "notch uuid=\(d.uuid.prefix(8)) panel=\(d.panel.frame) screen=\((d.panel.screen.flatMap(Displays.uuid(of:)) ?? "-").prefix(8)) alpha=\(d.panel.alphaValue) size=\(d.vm.notchSize) expanded=\(d.vm.isExpanded) state=\(d.vm.state) page=\(d.vm.homeOption.key) shown=\(d.vm.center.displayed?.kind.rawValue ?? "-")"
                    }
                    + Displays.all().map { "display \($0.uuid) \($0.label) builtIn=\($0.isBuiltIn) notch=\($0.hasNotch)" }
                try? (lines.joined(separator: "\n") + "\n").write(toFile: NSTemporaryDirectory() + "dmn-display.txt", atomically: true, encoding: .utf8)
            case "mcstate":   // 개발용: Mission Control 숨김 상태 기록
                let panel = self.notch?.panel
                try? "active=\(self.missionControl.isActive) hidden=\(self.vm.missionControlHidden) alpha=\(panel?.alphaValue ?? -1) mouseThrough=\(panel?.ignoresMouseEvents ?? false) expanded=\(self.vm.isExpanded)\n"
                    .write(toFile: NSTemporaryDirectory() + "dmn-mc.txt", atomically: true, encoding: .utf8)
            case "devdraftcount":   // 개발용: 입력 칸 글자 수만 기록 (내용은 남기지 않음)
                try? "\(self.chat.draft.count)\n".write(toFile: NSTemporaryDirectory() + "dmn-draft.txt", atomically: true, encoding: .utf8)
            case let c where c.hasPrefix("devcmd:"):   // 개발용: 이 앱에만 ⌘+키 (가상 키 코드, 예: devcmd:0 = ⌘A)
                if let code = CGKeyCode(c.dropFirst(7)) {
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                        e?.flags = .maskCommand
                        e?.postToPid(getpid())
                    }
                }
            case let c where c.hasPrefix("ppage:"):   // 개발용: 상시 항목 팝업에서 점 누르기 (예: ppage:aiUsage)
                if let kind = ActivityKind(rawValue: String(c.dropFirst(6))) { self.vm.selectPersistentPage(kind) }
            case "next": self.vm.switchExpandedPage(forward: true)
            case "prev": self.vm.switchExpandedPage(forward: false)
            case let c where c.hasPrefix("page"):
                if let i = Int(c.dropFirst(4)), let o = HomeOption(rawValue: i) { self.vm.selectHomeOption(o) }
            default: if let id = PreviewID(rawValue: command) { self.featurePreview.run(id) }
            }
    }

    #endif

    private func applyHomeFeatures(_ disabled: [String]) {
        if disabled.contains("calendar") { calendar.stop() } else { calendar.start() }
        if disabled.contains("timer"), timer.isActive { timer.cancel() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        media.stop()
        memo.saveNow()   // 쓰던 메모 (다시 시작·메모리 정리 재시작 포함)
    }


    // MARK: - 짧은 클릭

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

    /// 길게 누르면 자기 확장 화면이 열리는 활동 (나머지 알림은 확장 화면이 없다)
    private static let pagedKinds: Set<ActivityKind> = [.timer, .media, .recording, .call, .download, .aiUsage]

    /// 길게누르기·누름 반응이 있는지: 상세로 이미 떠 있는 알림과 HUD는 클릭만 받는다.
    private func hasLongPressAction(_ activity: NotchActivity?) -> Bool {
        guard let a = activity else { return true }   // 빈 노치: 홈 열기
        if Self.pagedKinds.contains(a.kind) { return true }
        if [.hud, .lock].contains(a.kind) { return false }
        if center.transient?.id == a.id { return !center.showingDetail }
        return true
    }

    /// 길게누르기: 확장 화면을 열면 true. 알림은 확장 화면 대신 상세 카드로 바꾼다.
    private func longPress(_ activity: NotchActivity?) -> Bool {
        guard let a = activity, !Self.pagedKinds.contains(a.kind) else { return true }
        guard hasLongPressAction(a) else { return false }
        // 상시 표시 항목(핫스팟·집중 모드 등): 팝업을 열고 다른 상시 항목을 점·스와이프로 넘겨 본다
        if center.transient?.id != a.id, center.persistentKinds.contains(a.kind) { return true }
        Haptics.perform()
        if center.transient?.id == a.id {
            center.promoteToDetail()   // 컴팩트 알림 → 상세 카드
        } else {
            // 상시 표시(핫스팟·집중 모드 등)는 같은 내용을 상세 카드로 잠깐 보여 준다
            var detail = a
            detail.id = UUID()
            detail.presentation = .detail
            detail.duration = nil
            center.post(detail)
        }
        return false
    }

    /// 알림·활동을 길게 눌러 연 확장 노치는 그 알림이 사라지면 자동으로 닫는다.
    /// (타이머·배터리·음악 화면은 알림이 없어도 내용이 있으므로 그대로 둔다)
    private func collapseIfActivityGone() {
        guard vm.isExpanded, case .activity(let kind) = vm.expandedPage,
              ![.timer, .media, .update].contains(kind) else { return }
        let stillShown = center.transient?.kind == kind || center.persistentKinds.contains(kind)
            || (kind == .recording && (recording.startedAt != nil || recording.finished != nil))   // 녹화 중·완료 화면 유지
        if !stillShown { vm.collapse() }
    }

    private func handleClick(_ activity: NotchActivity?, leftSide: Bool, on vm: DisplayNotchState) {
        guard let activity else { return }
        switch activity.kind {
        case .battery:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
        case .timer:
            vm.expand(page: .activity(.timer))
        case .media:
            media.openSourceApp()
        case .download:
            downloads.revealLastCompleted()
        case .recording:
            // 녹화 중 노치 왼쪽(녹화 시간·아이콘)을 누르면 정지·저장, 오른쪽은 녹화 화면 열기
            // 끝난 뒤의 '저장됨' 알림을 누르면 저장된 파일을 Finder에서 보여 준다
            if recording.startedAt == nil { recording.revealFinished(); center.dismissTransient() }
            else if leftSide { recording.stop() } else { vm.expand(page: .activity(.recording)) }
        case .call:
            // 접어 둔 수신 표시를 누르면 다시 카드로, 통화 중이면 통화 팝업
            if case .incoming = call.state { call.expandIncoming() } else { vm.expand(page: .activity(.call)) }
        case .airdrop:
            if let url = activity.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .screenshot:
            break   // 카드 안 버튼으로 조작
        case .chat:
            // 답변 완료 알림을 누르면 그 채팅으로
            chat.openAnswerNext()
            vm.openChat()
            center.dismissTransient()
        case .update:
            // 업데이트 완료 알림(오른쪽 문서 아이콘)을 누르면 업데이트 내용
            vm.expand(page: .activity(.update))
            center.dismissTransient()
        case .agent:
            // Claude Code·Codex 작업 완료: 그 에이전트가 돌던 앱을 연다
            AgentNotify.open(activity.targetApp)
            center.dismissTransient()
        default:
            center.dismissTransient()
        }
    }

    // MARK: - 메뉴

    private func setStatusItem(visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Dynamic MacNotch")
            item.menu = makeMenu()
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(T("설정…", "Settings…"), #selector(openSettings), key: ","))
        menu.addItem(item(T("권한 관리…", "Permissions…"), #selector(openPermissions)))
        menu.addItem(.separator())

        let demo = NSMenu()
        for d in PreviewID.menuItems {
            let mi = item(d.menuTitle, #selector(runDemo(_:)))
            mi.representedObject = d.rawValue
            demo.addItem(mi)
        }
        demo.addItem(.separator())
        let stop = item(T("모든 미리보기 중지", "Stop All Previews"), #selector(runDemo(_:)))
        stop.representedObject = PreviewID.stopAll.rawValue
        demo.addItem(stop)
        let demoItem = NSMenuItem(title: T("알림 미리보기", "Preview Alerts"), action: nil, keyEquivalent: "")
        demoItem.submenu = demo
        menu.addItem(demoItem)
        menu.addItem(item(T("홈 열기", "Open Home"), #selector(openHome)))
        menu.addItem(.separator())
        menu.addItem(item(T("업데이트 확인…", "Check for Updates…"), #selector(checkForUpdates)))
        menu.addItem(item(T("Dynamic MacNotch 다시 시작", "Restart Dynamic MacNotch"), #selector(restart), key: "r"))
        menu.addItem(item(T("Dynamic MacNotch 종료", "Quit Dynamic MacNotch"), #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @objc private func openSettings() { showSettings() }
    @objc private func openPermissions() { showPermissions(onboarding: false) }
    @objc private func openHome() { vm.expand(page: .home) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkForUpdates() { Updater.shared.check(userInitiated: true) }

    /// 오류·충돌이 의심될 때 사용자가 직접 앱을 다시 시작한다 (노치 우클릭 · 메뉴바 아이콘 메뉴).
    @objc private func restart() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 현재 프로세스가 완전히 끝난 뒤 다시 연다 (어댑터 등 하위 프로세스도 함께 정리됨)
        // 경로는 셸 문자열에 끼워 넣지 않고 인자($1, $2)로 넘긴다 (경로에 따옴표·$ 등이 있어도 안전)
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; open \"$2\"",
                          "sh", String(ProcessInfo.processInfo.processIdentifier), path]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func runDemo(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let d = PreviewID(rawValue: raw) else { return }
        featurePreview.run(d)
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

    private func closeHelper() {
        DistributedNotificationCenter.default().postNotificationName(Helper.helperNotification, object: "close",
                                                                     userInfo: nil, deliverImmediately: true)
    }
}
