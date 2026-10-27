import AppKit
import SwiftUI
import Combine
import CoreWLAN
import Intents
import IOBluetooth

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let center = ActivityCenter()
    private lazy var vm = NotchViewModel(center: center)
    private lazy var timer = TimerController(center: center, viewModel: vm)
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
    private lazy var featurePreview = FeaturePreview(
        center: center, battery: battery, media: media, call: call, focus: focus, timer: timer, screenshot: screenshot,
        lockScreen: { [weak self] in self?.lockScreen })
    private var previewObservers = Set<AnyCancellable>()
    private lazy var calendar = CalendarController(center: center)

    private var notch: NotchController?
    private var lockScreen: LockScreenManager?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let features = NotchFeatures(media: media, screenshot: screenshot, recording: recording, tray: tray, calendar: calendar, call: call)
        let root = NotchRootView(vm: vm, timer: timer, features: features) { [weak self] in self?.showSettings() }
        vm.verticalScrollHandler = { [weak self] dy in self?.timer.handleScroll(fingerDY: dy) ?? false }
        vm.verticalScrollEnded = { [weak self] in self?.timer.endScroll() }
        // 음악 팝업·작은 노치에서 두 손가락 좌우: 다음/이전 곡 (넘길 수 없는 미디어면 아무 일도 하지 않음)
        vm.onMediaSwipe = { [weak self] forward in
            guard let self, self.media.canSkip(forward ? 1 : -1) else { return }
            forward ? self.media.next() : self.media.previous()
            Haptics.perform()
        }
        vm.longPressShouldExpand = { [weak self] activity in self?.longPress(activity) ?? true }
        vm.allowsPressFeedback = { [weak self] activity in self?.hasLongPressAction(activity) ?? true }
        vm.onDetailSwipeUp = { [weak self] in
            guard let self else { return }
            if self.center.transient?.kind == .call { self.call.minimizeIncoming() } else { self.center.dismissTransient() }
        }
        notch = NotchController(
            vm: vm,
            rootView: root,
            menuProvider: { [weak self] in self?.makeMenu() ?? NSMenu() },
            clickHandler: { [weak self] activity, leftSide in self?.handleClick(activity, leftSide: leftSide) }
        )
        if let notch {
            let manager = LockScreenManager(center: center, vm: vm, media: media)
            manager.setLockNotchVisible = { [weak notch] visible in notch?.setLockPanelVisible(visible) }
            manager.prepareLockNotch = { [weak notch] in notch?.prepareLockPanel() }
            manager.setMainNotchHidden = { [weak notch] hidden, animated in notch?.setMainPanelHidden(hidden, animated: animated) }
            manager.lockNotchAvailable = { [weak notch] in notch?.lockPanelReady ?? false }
            manager.refreshNotch = { [weak notch] in notch?.forceRefresh() }
            manager.start()
            lockScreen = manager
            notch.isLocked = { [weak manager] in manager?.isLocked ?? false }
        }
        timer.$editingUnit
            .removeDuplicates()
            .filter { $0 == nil }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.notch?.releaseKeyFocus() } }
            .store(in: &cancellables)
        vm.$isExpanded
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.timer.endEditing()
                DispatchQueue.main.async { self?.notch?.releaseKeyFocus() }
            }
            .store(in: &cancellables)
        battery.start()
        network.start()
        bluetooth.start()
        focus.start()
        hud.start()
        media.start()
        downloads.onAirDropReceived = { [weak self] urls in self?.tray.airDropReceived(urls) }
        downloads.start()
        screenshot.start()
        recording.start()
        call.start()
        calendar.start()

        settings.$showStatusItem
            .sink { [weak self] show in self?.setStatusItem(visible: show) }
            .store(in: &cancellables)

        // 자동 업데이트: 상태는 노치 상세 알림으로
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
        vm.$isHovering.merge(with: vm.$isExpanded).filter { $0 }
            .sink { [weak self] _ in self?.media.noteTestInteraction() }
            .store(in: &previewObservers)
        Updater.shared.start()

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
            case "diag": self.writeDiagnostics()
            case "media": self.vm.expand(page: .activity(.media))
            case "shot": self.screenshot.debugPresentClipboard()
            case let c where c.hasPrefix("popup:"):
                if let kind = ActivityKind(rawValue: String(c.dropFirst(6))) { self.vm.expand(page: .activity(kind)) }
            case "settings": self.showSettings()
            case "permissions": self.showPermissions(onboarding: false)
            case "closewin": self.closeHelper()
            case "update": Updater.shared.check(userInitiated: true)   // 개발용: 지금 업데이트 확인
            case let c where c.hasPrefix("call:"): self.call.debugSimulate(String(c.dropFirst(5)))   // 개발용: 가짜 통화
            case "longpress":   // 개발용: 길게누르기와 같은 판단
                if self.vm.longPressShouldExpand?(self.center.displayed) ?? true {
                    self.vm.expand(page: self.center.displayed.map { .activity($0.kind) } ?? .home)
                }
            case "sizes":   // 개발용: 홈 기본·카메라 크기
                let line = "home=\(self.vm.expandedBaseSize) camera=\(self.vm.cameraSize) notch=\(self.vm.notchSize) panel=\(NotchGeometry.panelSize) dots=\(NotchViewModel.dotsAreaHeight)\n"
                try? line.write(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DynamicMacNotch-sizes.txt"), atomically: true, encoding: .utf8)
            case let c where c.hasPrefix("shotfile:"): self.screenshot.debugPresentFile(URL(fileURLWithPath: String(c.dropFirst(9))))
            case "shotdelete": self.screenshot.delete()
            case "memtest":   // 개발용: 기준을 1MB로 낮춰 지킴이 동작(캐시 비우기 → 쉬는 동안 재시작)을 시험
                MemoryGuard.testLimitMB = 1
                MemoryGuard.shared.debugCheckNow()
            case "skipnext": self.vm.onMediaSwipe?(true)
            case "skipprev": self.vm.onMediaSwipe?(false)
            case "recstop": self.recording.stop()   // 개발용: 녹화 정지(⌃⌘Esc)
            case "recstate":   // 개발용: 녹화 감지 결과를 로그로
                let line = "\(Date()) \(RecordingMonitor.debugState()) recording=\(RecordingMonitor.systemIsRecording()) startedAt=\(self.recording.startedAt.map { "\($0)" } ?? "nil") persistent=\(self.center.persistentKinds.contains(.recording))\n"
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DynamicMacNotch-rec.txt")
                if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? line.write(to: url, atomically: true, encoding: .utf8) }
            case let c where c.hasPrefix("inject:"):   // 개발용: 가짜 재생 보고 → 결과를 로그 파일에
                self.media.debugInject(String(c.dropFirst(7)))
                let line = "\(c) => \(self.media.debugState)\n"
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DynamicMacNotch-media.txt")
                if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? line.write(to: url, atomically: true, encoding: .utf8) }
            case "focuson": self.focus.preview(on: true)    // 개발용: 집중 모드 알림 미리보기
            case "focusoff": self.focus.preview(on: false)
            case "pick": FilePicker.choose(.tray) { self.tray.add($0) }   // 개발용: 트레이 파일 선택 창
            case "volrow": self.vm.toggleMediaVolume()   // 개발용: 음악 팝업 음량 줄 토글
            case "favtoggle": self.media.toggleFavorite()   // 개발용: 즐겨찾기 토글
            case "outmenu": OutputMenuView.visible?.showMenu(autoClose: 3)   // 개발용: 출력 기기 메뉴 3초간 표시
            case "digits":   // 개발용: 1의 자리만 바뀌는 숫자 굴림 확인
                for (i, v) in [0.41, 0.42, 0.43, 0.44].enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) {
                        self.center.post(NotchActivity(kind: .hud, priority: ActivityPriority.hud, duration: 1.5,
                                                       symbol: "speaker.wave.2.fill", value: .bigNumber(v)))
                    }
                }
            case let c where c.hasPrefix("trayadd:"):   // 개발용
                self.tray.add(String(c.dropFirst(8)).split(separator: "|").map { URL(fileURLWithPath: String($0)) })
            case "trayselect":   // 개발용: 첫 번째와 세 번째를 ⌘ 선택
                let items = self.tray.items
                if items.count >= 3 {
                    self.tray.select(items[0], command: false, shift: false)
                    self.tray.select(items[2], command: true, shift: false)
                }
            case "trayclear": self.tray.clear()
            case "hide": self.center.setPersistentHidden(true)
            case "unhide": self.center.setPersistentHidden(false)
            case "lock": self.lockScreen?.lock(preview: true)
            case "unlock": self.lockScreen?.unlock()
            case "lockfull": self.lockScreen?.openFull()
            case "saveron": self.lockScreen?.setScreenSaver(active: true)    // 개발용: 화면 보호기 시작/끝 흉내
            case "saveroff": self.lockScreen?.setScreenSaver(active: false)
            case "next": self.vm.switchExpandedPage(forward: true)
            case "prev": self.vm.switchExpandedPage(forward: false)
            case let c where c.hasPrefix("page"):
                if let i = Int(c.dropFirst(4)), let o = HomeOption(rawValue: i) { self.vm.selectHomeOption(o) }
            default: if let id = PreviewID(rawValue: command) { self.featurePreview.run(id) }
            }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        media.stop()
    }

    /// 개발용: 각 모니터가 읽는 값을 ~/Library/Logs/NotchIsland-diag.txt에 기록한다.
    #if DEV
    private func writeDiagnostics() {
        let device = AudioOutput.defaultDevice()
        let iface = CWWiFiClient.shared().interface()
        let lines = [
            "time: \(Date())",
            "hud.tapActive: \(hud.tapActive)",
            "display brightness: \(Brightness.display().map { String($0) } ?? "n/a") available=\(Brightness.displayAvailable)",
            "keyboard brightness: \(Brightness.keyboard().map { String($0) } ?? "n/a") available=\(Brightness.keyboardAvailable)",
            "output: \(AudioOutput.name(device) ?? "?") volume=\(AudioOutput.volume(device).map { String($0) } ?? "n/a") muted=\(AudioOutput.isMuted(device)) symbol=\(AudioOutput.currentSymbol() ?? "builtin")",
            "wifi: power=\(iface?.powerOn() ?? false) ssid=\(iface?.ssid() ?? "nil") channel=\(iface?.wlanChannel()?.channelNumber ?? -1)",
            "vpn: \(NetworkMonitor.activeVPNName() ?? "none")",
            "fullDiskAccess(db readable): \(FileManager.default.isReadableFile(atPath: NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json")) check=\(PermissionsManager.hasFullDiskAccess())",
            "focus(db): \(FocusMonitor.readActiveMode()?.name ?? "none")",
            "focus(fallback authorized): \(INFocusStatusCenter.default.authorizationStatus == .authorized)",
            "battery: \(String(describing: BatteryMonitor.read()))",
            "media: adapter=\(media.adapterRunning) now=\(media.nowPlaying.map { "\($0.title) / \($0.artist) playing=\($0.playing) app=\($0.bundleID ?? "?")" } ?? "none") artwork=\(media.artwork != nil)",
            "recording: \(RecordingMonitor.systemIsRecording())",
            "calendar: authorized=\(calendar.authorized) events=\(calendar.events.count)",
            "tray: \(tray.items.count) items",
            "settings.hudStyle: \(settings.hudStyle.rawValue)",
            "lockPanelReady(SkyLight): \(notch?.lockPanelReady ?? false)",
        ]
        var bt: [String] = []
        for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] {
            bt.append("bt: \(d.name ?? "?") major=\(d.deviceClassMajor) minor=\(String(format: "0x%02x", d.deviceClassMinor)) pnp=\(BluetoothMonitor.pnpSymbol(for: d) ?? "-") icon=\(BluetoothMonitor.symbol(for: d)) cached=\(BluetoothMonitor.cachedSymbol(d.addressString ?? "") ?? "-") connected=\(d.isConnected()) battery=\(BluetoothMonitor.accessoryBattery(name: d.name ?? "").map { "main=\($0.main ?? -1) L=\($0.left ?? -1) R=\($0.right ?? -1) case=\($0.caseLevel ?? -1) primary=\($0.primary ?? -1)" } ?? "none")")
        }
        var fav: [String] = []
        for prop in ["favorited", "loved"] {
            var err: NSDictionary?
            let r = NSAppleScript(source: "tell application id \"com.apple.Music\" to get \(prop) of current track")?.executeAndReturnError(&err)
            fav.append("music.\(prop): \(r.map { String($0.booleanValue) } ?? "nil") err=\(err?["NSAppleScriptErrorNumber"] ?? "-") \(err?["NSAppleScriptErrorMessage"] ?? "")")
        }
        fav.append("media.favorited: \(String(describing: media.favorited))")
        for d in AudioOutput.outputDevices() {
            fav.append("out: \(AudioOutput.name(d) ?? "?") uid=\(AudioOutput.uid(d) ?? "?") transport=\(String(format: "%08x", AudioOutput.transport(d))) symbol=\(AudioOutput.deviceSymbol(d))\(d == device ? " *" : "")")
        }
        fav.append("route: \(OutputRoute.shared.name) \(OutputRoute.shared.symbol)")
        let allLines = lines + fav + bt
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DynamicMacNotch-diag.txt")
        try? allLines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    // MARK: - 짧은 클릭

    /// 자동 재시작해도 사용자가 알아채지 못할 때: 노치가 닫혀 있고 알림·조작·진행 중인 작업이 없음.
    /// (음악 재생은 다른 앱에서 계속되므로 막지 않는다)
    private func isIdleForRelaunch() -> Bool {
        let busyKinds: Set<ActivityKind> = [.download, .airdrop, .recording, .call, .demo, .timer]
        return !vm.isExpanded && !vm.isHovering && !vm.isFileDragging
            && center.transient == nil && center.persistentKinds.isDisjoint(with: busyKinds)
            && recording.startedAt == nil && call.state == .idle && !timer.isActive
            && lockScreen?.isLocked != true && helperProcess?.isRunning != true && !FilePicker.isRunning
            && !media.testActive && !call.previewActive && screenshot.shot == nil
    }

    /// 길게 누르면 자기 확장 화면이 열리는 활동 (나머지 알림은 확장 화면이 없다)
    private static let pagedKinds: Set<ActivityKind> = [.timer, .media, .recording, .call, .download]

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
              ![.timer, .media].contains(kind) else { return }
        let stillShown = center.transient?.kind == kind || center.persistentKinds.contains(kind)
            || (kind == .recording && (recording.startedAt != nil || recording.finished != nil))   // 녹화 중·완료 화면 유지
        if !stillShown { vm.collapse() }
    }

    private func handleClick(_ activity: NotchActivity?, leftSide: Bool) {
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
        vm.collapse()
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
