import AppKit

#if DEV
extension AppDelegate {
    /// 개발용: `scripts/notchctl <명령>`으로 테스트 액티비티·화면을 띄운다 (개발 빌드에만 포함).
    func handleDevCommand(_ command: String) {
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
                if self.hub.shared.longPressShouldExpand?(self.vm.displayed) ?? true {
                    self.vm.expand(page: self.vm.longPressPage(for: self.vm.displayed))
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
            case let c where c.hasPrefix("devmouse:"):   // 개발용: 노치 창에 왼쪽 버튼 드래그 이벤트 (화면 좌표 "x1,y1,x2,y2", 끝에 ,shift ,hold(놓지 않음) ,up(놓기만) 가능). 두 점이 같으면 클릭.
                let parts = c.dropFirst(9).split(separator: ",")
                let v = parts.compactMap { Double($0) }
                if v.count == 4, let panel = self.notch?.panel, let screen = panel.screen {
                    panel.ignoresMouseEvents = false
                    let flags: NSEvent.ModifierFlags = parts.last == "shift" ? .shift : []
                    func point(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: x - panel.frame.minX, y: screen.frame.maxY - y - panel.frame.minY) }
                    func send(_ type: NSEvent.EventType, _ p: NSPoint) {
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { panel.sendEvent(e) }
                    }
                    if parts.last != "up" { send(.leftMouseDown, point(v[0], v[1])) }
                    if v[0] != v[2] || v[1] != v[3] {
                        for i in 1...10 {
                            let f = Double(i) / 10
                            send(.leftMouseDragged, point(v[0] + (v[2] - v[0]) * f, v[1] + (v[3] - v[1]) * f))
                        }
                    }
                    if parts.last != "hold" { send(.leftMouseUp, point(v[2], v[3])) }
                }
            case "traystate":   // 개발용: 트레이 상태 기록
                let selected = self.tray.items.filter { self.tray.selection.contains($0.id) }.map { ($0.path as NSString).lastPathComponent }.joined(separator: ",")
                let cursor = self.tray.items.first { $0.id == self.tray.picked.cursor }.map { ($0.path as NSString).lastPathComponent } ?? "-"
                let key = self.notch?.panel.isKeyWindow ?? false
                let line = "items=\(self.tray.items.count) selected=[\(selected)] cursor=\(cursor) key=\(key) responder=\(String(describing: self.notch?.panel.firstResponder.map { type(of: $0) }))\n"
                try? line.write(toFile: NSTemporaryDirectory() + "dmn-tray.txt", atomically: true, encoding: .utf8)
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
                    let flags: NSEvent.ModifierFlags = parts.count < 2 ? [] : (parts[1] == "both" ? [.command, .shift] : parts[1] == "cmd" ? .command : .shift)
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
            case "screenparams":   // 개발용: 화면 구성 변경 알림을 연달아 보낸다 (모아서 한 번만 처리하는지)
                for _ in 0..<5 { NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp) }
            case let c where c.hasPrefix("panelshidden:"):   // 개발용: 잠금 때처럼 모든 노치 숨김·보임
                self.hub.setMainPanelsHidden(c.hasSuffix("1"), animated: false)
            case let c where c.hasPrefix("monitordemand:"):   // 개발용: 자원 수요 지정 (monitordemand:cpu,mem / monitordemand: 는 해제)
                let metrics = Set(c.dropFirst(14).split(separator: ",").compactMap { MonitorMetric(rawValue: String($0)) })
                ResourceSampler.shared.setDemand(.dev, metrics)
            case let c where c.hasPrefix("monitortest:"):   // 개발용: 칸 그리기 방식 비교 (가려지지 않게 통화 순위로 띄운다). full = 매 틱 활동 게시, live = 활동 한 번 + 작은 뷰, off
                self.monitorTest?.cancel()
                self.monitorTest = nil
                self.center.removePersistent(.call)
                let mode = String(c.dropFirst(12))
                func activity(_ left: ActivityValue, _ right: ActivityValue) -> NotchActivity {
                    NotchActivity(kind: .call, priority: ActivityPriority.pinned, symbol: "cpu", tint: .green, value: right,
                                  wing: NotchActivity.compactWing, leadingValue: left)
                }
                if mode == "live" {
                    self.center.setPersistent(activity(.metric(.cpu, ring: false), .metric(.mem, ring: false)))
                } else if mode == "full" {
                    let readings = ResourceSampler.shared.readings
                    self.monitorTest = readings.$snapshot.sink { s in
                        self.center.setPersistent(activity(.usage(label: "CPU", percent: s.cpu.map(Double.init), ring: false),
                                                           .usage(label: "MEM", percent: s.mem?.percent, ring: false)))
                    }
                }
            case let c where c.hasPrefix("monitorsample:"):   // 개발용: 한도 하나인 AI 사용량 (monitorsample:claude)
                if let service = AIService(rawValue: String(c.dropFirst(14))) {
                    let sample = ServiceUsage(windows: [UsageWindow(percent: 37, resetsAt: Date().addingTimeInterval(3 * 86400), seconds: UsageWindow.week)], fetched: Date())
                    var a = MonitorActivity.ai(service: service, usage: sample, ring: false)
                    a.kind = .call   // 다른 상시 표시에 가려지지 않게
                    self.center.setPersistent(a)
                } else {
                    self.center.removePersistent(.call)
                }
            case "monitorstate":   // 개발용: 자원 측정 상태 기록
                let r = ResourceSampler.shared
                let s = r.readings.snapshot
                let history = r.readings.history.map { "\($0.key.rawValue):\($0.value.count)" }.sorted().joined(separator: ",")
                let line = "active=\(r.active.map(\.rawValue).sorted()) running=\(r.isRunning) interval=\(r.interval) ticks=\(r.ticks) gpu=\(r.gpuAvailable) "
                    + "cpu=\(s.cpu.map(String.init) ?? "-") gpu%=\(s.gpu.map(String.init) ?? "-") mem=\(s.mem.map { String(format: "%.1f%%", $0.percent) } ?? "-") "
                    + "net=\(s.net.map { "\($0.received)/\($0.sent)" } ?? "-") history=[\(history)] footprint=\(String(format: "%.1f", MemoryGuard.footprintMB()))\n"
                try? line.write(toFile: NSTemporaryDirectory() + "dmn-monitor.txt", atomically: true, encoding: .utf8)
            case "displaystate":   // 개발용: 노치가 어느 디스플레이에 있는지 기록
                let lines = ["selection=\(self.settings.notchDisplays) paused=\(self.center.paused)"]
                    + self.hub.displays.map { d in
                        "notch uuid=\(d.uuid.prefix(8)) panel=\(d.panel.frame) screen=\((d.panel.screen.flatMap(Displays.uuid(of:)) ?? "-").prefix(8)) alpha=\(d.panel.alphaValue) size=\(d.vm.notchSize) expanded=\(d.vm.isExpanded) state=\(d.vm.state) page=\(d.vm.homeOption.key) shown=\(d.vm.displayed?.kind.rawValue ?? "-")"
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
}
#endif
