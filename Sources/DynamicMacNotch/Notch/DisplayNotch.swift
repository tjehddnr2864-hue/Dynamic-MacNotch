import AppKit
import SwiftUI
import Combine

/// 디스플레이 하나의 노치. 패널 배치, 마우스 통과/호버 판정, 제스처 매핑을 맡는다 (가이드라인 4장).
final class DisplayNotch: NotchGestureDelegate {
    /// 이 노치가 놓인 디스플레이
    let uuid: String
    let panel = NotchPanel()
    /// 잠금화면 전용 노치 창. 같은 뷰를 그리며 SkyLight 전용 Space(잠금화면 위)에 들어가 있고, 잠금 중에만 보인다.
    /// 평소 노치(panel)는 일반 레이어에 두어 파일 드래그·드롭이 정상 동작하게 한다.
    private lazy var lockPanel: NotchPanel = {
        lockPanelMade = true
        let panel = NotchPanel()
        panel.ignoresMouseEvents = true
        return panel
    }()
    private var lockPanelMade = false
    private(set) var lockPanelReady = false
    private var lockRootView: NotchRootView?
    private var lockPanelFrame = CGRect.zero
    let vm: DisplayNotchState
    private let hostingView: NotchHostingView
    private let settings = AppSettings.shared
    private let menuProvider: () -> NSMenu
    /// 짧은 클릭: (표시 중인 활동, 노치 가운데보다 왼쪽을 눌렀는지)
    private let clickHandler: (DisplayNotchState, NotchActivity?, Bool) -> Void
    /// 이 노치의 호버 상태가 바뀔 때 (알림 시간 멈춤은 NotchHub가 모아서 정한다)
    var onHoverChanged: (() -> Void)?

    private var monitors: [Any] = []
    /// 잠금 중에는 노치를 펼치지 않는다 (잠금화면 정보 노출 방지).
    var isLocked: () -> Bool = { false }
    private var cancellables = Set<AnyCancellable>()

    // 길게누르기
    private var longPressWork: DispatchWorkItem?
    private var pressFired = false
    private var pressOrigin: NSPoint?
    private var lastCollapse = Date.distantPast

    // 호버
    private var hoverOpenWork: DispatchWorkItem?

    // 파일 드래그
    private var dragBaseline = NSPasteboard(name: .drag).changeCount

    // 스와이프
    private var scrollAccum = CGSize.zero

    init(uuid: String,
         vm: DisplayNotchState,
         rootView: NotchRootView,
         menuProvider: @escaping () -> NSMenu,
         clickHandler: @escaping (DisplayNotchState, NotchActivity?, Bool) -> Void) {
        self.uuid = uuid
        self.vm = vm
        self.menuProvider = menuProvider
        self.clickHandler = clickHandler
        hostingView = NotchHostingView(rootView: rootView)
        hostingView.gestureDelegate = self
        panel.contentView = hostingView
        lockRootView = rootView   // 잠금화면 노치 창은 잠겨 있는 동안에만 이 뷰를 붙여 그린다

        reposition()
        panel.orderFrontRegardless()
        installMonitors()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
    }

    /// 디스플레이에서 노치를 내린다. 호스팅 뷰를 떼어 내야 화면·메모리가 함께 돌아온다.
    func tearDown() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        cancellables = []
        longPressWork?.cancel()
        hoverOpenWork?.cancel()
        hideWork?.cancel()
        panel.orderOut(nil)
        panel.contentView = nil
        lockRootView = nil
        if lockPanelMade {
            lockPanel.orderOut(nil)
            lockPanel.contentView = nil
        }
    }

    /// 숫자 입력이 끝나면 키보드 포커스를 원래 쓰던 앱으로 돌려준다.
    /// 키 창을 잠깐 내렸다 올리면 창 서버가 활성 앱의 창을 다시 키 창으로 만든다.
    func releaseKeyFocus() {
        guard panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// 잠금화면 노치 창을 미리 잠금화면 위 Space로 옮겨 둔다 (평소에는 화면 밖, 투명).
    func prepareLockPanel() {
        guard !lockPanelReady else { return }
        lockPanel.alphaValue = 0
        lockPanel.setFrame(lockPanelFrame.offsetBy(dx: 0, dy: 4000), display: false)
        lockPanel.orderFrontRegardless()
        lockPanelReady = SkyLight.moveToLockScreenSpace(lockPanel)
    }

    /// 평소 노치 창을 숨기거나 다시 보인다 (잠금 전환 동안 데스크탑과 함께 움직이지 않게).
    func setMainPanelHidden(_ hidden: Bool, animated: Bool) {
        lockHidden = hidden
        applyPanelVisibility(animated: animated)
    }

    // 창을 숨기는 이유가 여럿이다. 알파는 여기서만 정해 서로 덮어쓰지 않게 한다.
    private var lockHidden = false
    private var missionControlHidden = false
    private var hideWork: DispatchWorkItem?

    private func applyPanelVisibility(animated: Bool) {
        if lockHidden || missionControlHidden {
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
        } else if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }
    }

    /// Mission Control이 열리면 노치의 양쪽이 줄어들며 사라지고, 끝나면 돌아온다.
    /// 창을 내리지 않고 투명하게만 한다 (내리면 Space 전환 때 깜빡이고 순서가 틀어질 수 있다).
    func setMissionControlActive(_ active: Bool) {
        hideWork?.cancel()
        hideWork = nil
        let reduce = vm.reduceMotion
        if active {
            cancelPress()
            hoverOpenWork?.cancel()
            vm.endPress()
            vm.isHovering = false
            if vm.isFileDragging { vm.endFileDrag(dropped: false) }
            collapse()
            panel.ignoresMouseEvents = true   // 그 자리의 Mission Control 창을 누를 수 있게
            withAnimation(reduce ? .easeOut(duration: 0.1) : .easeIn(duration: 0.2)) { vm.missionControlHidden = true }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.missionControlHidden = true
                self.applyPanelVisibility(animated: false)
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0.1 : 0.2), execute: work)
        } else {
            missionControlHidden = false
            applyPanelVisibility(animated: false)
            withAnimation(reduce ? .easeOut(duration: 0.1) : .spring(response: 0.28, dampingFraction: 0.85)) { vm.missionControlHidden = false }
        }
    }

    /// 잠금 중에만 잠금화면 노치를 보인다. 풀리면 화면 밖으로 치워 평소 동작(드래그 등)에 끼어들지 않게 한다.
    func setLockPanelVisible(_ visible: Bool) {
        prepareLockPanel()
        if visible {
            if lockPanel.contentView == nil, let root = lockRootView {
                lockPanel.contentView = NSHostingView(rootView: root)
            }
            lockPanel.setFrame(lockPanelFrame, display: true)
            lockPanel.alphaValue = 1
            lockPanel.orderFrontRegardless()
        } else {
            lockPanel.alphaValue = 0
            lockPanel.setFrame(lockPanelFrame.offsetBy(dx: 0, dy: 4000), display: false)
            // 숨긴 동안에는 내용을 떼어 낸다: 평소에 같은 화면을 두 번 그리지 않게 (CPU·메모리 절약)
            lockPanel.contentView = nil
        }
    }

    /// 가려져 있던 동안 멈췄던 화면 갱신을 다시 하게 한다 (잠금화면 전환 직후).
    func forceRefresh() {
        vm.objectWillChange.send()
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        hostingView.display()
        if lockPanelMade {
            lockPanel.contentView?.needsLayout = true
            lockPanel.contentView?.display()
        }
    }

    // MARK: - 배치

    func reposition() {
        guard let screen = Displays.screens.first(where: { Displays.uuid(of: $0) == uuid }) else { return }
        let notch = NotchGeometry.notchRect(on: screen)
        vm.notchSize = notch.size
        vm.hasPhysicalNotch = NotchGeometry.hasPhysicalNotch(screen)
        let size = NotchGeometry.panelSize
        let frame = CGRect(x: notch.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        lockPanelFrame = frame
        if lockPanelMade, lockPanel.alphaValue > 0 { lockPanel.setFrame(frame, display: true) }
    }

    /// 현재 보이는 노치 도형의 화면 좌표 사각형.
    private var interactiveRect: CGRect {
        let size = vm.interactiveSize
        let f = panel.frame
        return CGRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    // MARK: - 마우스 감시

    private func installMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in self?.updateHover() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] e in self?.updateHover(); return e }) {
            monitors.append(m)
        }
        // 파일 드래그 감지: 드래그 페이스트보드에 파일이 올라왔는지 보고, 노치 근처로 오면 확장
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            self?.dragBaseline = NSPasteboard(name: .drag).changeCount
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in
            self?.checkFileDrag()
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            guard let self, self.vm.isFileDragging else { return }
            // 노치 밖에 놓았으면 잠시 뒤 닫는다 (노치에 놓은 경우는 onDrop이 먼저 처리)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.vm.endFileDrag(dropped: false) }
        }) {
            monitors.append(m)
        }
        // 다른 디스플레이의 노치를 눌러도 '바깥 클릭'이다 (같은 앱이라 위의 전역 감시에는 오지 않는다)
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self, self.vm.isExpanded, event.window !== self.panel, !FilePicker.isChoosing else { return event }
            self.collapse()
            return event
        }) {
            monitors.append(m)
        }
        // 바깥 클릭 → 확장 닫기
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            // 파일 선택 창을 쓰는 동안의 클릭은 '바깥 클릭'이 아니다
            guard let self, self.vm.isExpanded, !FilePicker.isChoosing else { return }
            if !self.interactiveRect.contains(NSEvent.mouseLocation) { self.collapse() }
        }) {
            monitors.append(m)
        }
    }

    /// 파일을 든 커서가 노치 옆 막대에 닿았는지
    private func checkFileDragBar(_ loc: CGPoint) {
        guard let bar = vm.fileDragBarRect else { return }
        let f = panel.frame
        let rect = CGRect(x: f.midX + bar.minX, y: f.maxY - bar.maxY, width: bar.width, height: bar.height)
        if rect.contains(loc) { vm.switchFileDragPage() }
    }

    private func checkFileDrag() {
        // 에어드랍·트레이를 끄면 파일을 노치로 끌어와도 아무 일도 하지 않는다
        guard !vm.isFileDragging, !vm.missionControlHidden, vm.acceptsFileDrag else { return }
        // 먼저 커서 위치(계산만)로 거르고, 노치 근처일 때만 드래그 페이스트보드(프로세스 간 통신)를 확인한다.
        let loc = NSEvent.mouseLocation
        let f = panel.frame
        // 노치 중심 좌우 ±300pt, 화면 위에서 설정 높이 안으로 들어오면 확장 (가장자리 도달 전에 드롭 영역을 먼저 내민다)
        let zone = CGRect(x: f.midX - 300, y: f.maxY - settings.dragZoneHeight, width: 600, height: settings.dragZoneHeight)
        guard zone.contains(loc) else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragBaseline,
              pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        vm.beginFileDrag()
        panel.ignoresMouseEvents = false
    }

    func refreshHover() { updateHover() }

    private func updateHover() {
        guard !vm.missionControlHidden else { return }
        let loc = NSEvent.mouseLocation
        checkFileDragBar(loc)
        // 빠른 거르기: 노치 패널 높이보다 아래에 있고 이미 호버 상태가 아니면 아무것도 계산하지 않는다.
        // (마우스가 움직일 때마다 불리므로 대부분의 이동은 여기서 바로 끝난다)
        if loc.y < panel.frame.minY || abs(loc.x - panel.frame.midX) > panel.frame.width / 2 {
            if !vm.isHovering && panel.ignoresMouseEvents { return }
        }
        let inside = interactiveRect.insetBy(dx: -4, dy: -4).contains(loc)
        // 노치 도형 밖에서는 클릭이 아래 메뉴바·앱으로 통과한다.
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        guard inside != vm.isHovering else { return }
        vm.isHovering = inside
        onHoverChanged?()

        hoverOpenWork?.cancel()
        if inside, settings.hoverToOpen, !vm.isExpanded {
            let work = DispatchWorkItem { [weak self] in self?.expand(haptic: false) }
            hoverOpenWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    // MARK: - 제스처

    private func expand(haptic: Bool) {
        guard !isLocked(), !vm.missionControlHidden, !vm.isExpanded, Date().timeIntervalSince(lastCollapse) > 0.3 else { return }
        // 알림은 확장 화면 대신 앱이 처리한다 (컴팩트 → 상세 카드, 상세 → 반응 없음)
        if let decide = vm.shared.longPressShouldExpand, !decide(vm.displayed) {
            vm.endPress()
            return
        }
        vm.expand(page: vm.longPressPage(for: vm.displayed))
        if haptic { Haptics.perform() }
    }

    private func collapse() {
        vm.collapse()
        lastCollapse = Date()
    }

    private func cancelPress() {
        longPressWork?.cancel()
        longPressWork = nil
        pressOrigin = nil
    }

    /// 이번 누름은 확장하지 않는다 (HUD·자물쇠처럼 누를 때 길게누르기가 없던 항목 — 누르는 사이 HUD가 사라져도 유지)
    private var pressBlocked = false

    func pointerDown(_ event: NSEvent) {
        guard !vm.isExpanded else { return }
        pressFired = false
        pressOrigin = NSEvent.mouseLocation
        // 상세 알림처럼 길게누르기가 없는 경우: 누름 반응·길게누르기 없이 클릭만 받는다
        pressBlocked = !(vm.shared.allowsPressFeedback?(vm.displayed) ?? true)
        guard !pressBlocked else { return }
        let duration = settings.longPressDuration
        vm.beginPress(duration: duration)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pressFired = true
            self.expand(haptic: true)
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func pointerDragged(_ event: NSEvent) {
        guard let origin = pressOrigin else { return }
        let p = NSEvent.mouseLocation
        if hypot(p.x - origin.x, p.y - origin.y) > 6 {
            cancelPress()
            vm.endPress()
        }
    }

    func pointerUp(_ event: NSEvent) {
        let wasPressing = pressOrigin != nil
        let leftSide = (pressOrigin?.x ?? panel.frame.midX) < panel.frame.midX
        cancelPress()
        guard !vm.isExpanded else { return }
        vm.endPress()
        if wasPressing, !pressFired {
            // 짧은 클릭: 액티비티 소스 열기. Idle에서는 아무것도 하지 않는다.
            clickHandler(vm, vm.displayed, leftSide)
        }
    }

    func pressure(_ event: NSEvent) {
        guard settings.forceTouchEnabled, !vm.isExpanded, pressOrigin != nil, !pressBlocked else { return }
        if event.stage >= 2 {
            // 깊게누르기: 길게누르기를 기다리지 않고 즉시 확장
            cancelPress()
            pressFired = true
            expand(haptic: true)
        } else if event.stage == 1 {
            vm.setForcePressure(CGFloat(event.pressure))
        }
    }

    func secondaryClick(_ event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: view)
    }

    private var scrollConsumedByPage = false

    func scroll(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return }
        let natural = event.isDirectionInvertedFromDevice
        guard vm.isExpanded else {
            collapsedScroll(event, natural: natural)
            return
        }
        switch event.phase {
        case .began:
            scrollAccum = .zero
            scrollConsumedByPage = false
        case .changed:
            scrollAccum.width += event.scrollingDeltaX
            scrollAccum.height += event.scrollingDeltaY
            let fingerDY = natural ? -event.scrollingDeltaY : event.scrollingDeltaY
            // 타이머 시·분·초 칸 위에서의 세로 스크롤은 값 조절에 쓴다.
            if scrollConsumedByPage || abs(scrollAccum.height) >= abs(scrollAccum.width),
               vm.shared.verticalScrollHandler?(fingerDY) == true {
                scrollConsumedByPage = true
                return
            }
            if abs(scrollAccum.width) > abs(scrollAccum.height) {
                // 콘텐츠가 손가락 방향으로 따라온다.
                vm.dragPage(by: natural ? scrollAccum.width : -scrollAccum.width)
            }
        case .ended, .cancelled:
            defer { scrollAccum = .zero }
            if scrollConsumedByPage {
                scrollConsumedByPage = false
                vm.shared.verticalScrollEnded?()
                return
            }
            let fingerUp = natural ? -scrollAccum.height : scrollAccum.height
            let contentDX = natural ? scrollAccum.width : -scrollAccum.width
            if abs(scrollAccum.height) > abs(scrollAccum.width) {
                vm.cancelDrag()
                // 두 손가락으로 위로 쓸어 올림 → 닫기 (메모 본문처럼 포인터 아래 내용이 스크롤되는 중이면 스크롤로 본다)
                if fingerUp > 40, !isOverScrollableContent(event) { collapse() }
            } else if abs(contentDX) > 50 {
                vm.switchExpandedPage(forward: contentDX < 0)
            } else {
                vm.cancelDrag()
            }
        default:
            break
        }
    }

    /// 포인터 아래에 실제로 넘치는(스크롤되는) 내용이 있는지
    private func isOverScrollableContent(_ event: NSEvent) -> Bool { isScrollable(atWindowPoint: event.locationInWindow) }

    func isScrollable(atWindowPoint windowPoint: NSPoint) -> Bool {
        guard let host = panel.contentView, let superview = host.superview else { return false }
        let point = superview.convert(windowPoint, from: nil)
        guard let scroll = host.hitTest(point)?.enclosingScrollView, let doc = scroll.documentView else { return false }
        return doc.frame.height > scroll.contentView.bounds.height + 1
    }

    /// 확장되지 않은 노치 위 두 손가락 제스처 (가이드라인 추가 요구 7):
    /// 위로 = 상시 표시 항목을 노치 안으로 숨김, 아래로 = 다시 표시. 숨길/보일 것이 없으면 아무 일도 하지 않는다.
    private func collapsedScroll(_ event: NSEvent, natural: Bool) {
        switch event.phase {
        case .began:
            scrollAccum = .zero
        case .changed:
            scrollAccum.width += event.scrollingDeltaX
            scrollAccum.height += event.scrollingDeltaY
        case .ended, .cancelled:
            defer { scrollAccum = .zero }
            // 음악이 작은 노치에 떠 있을 때 두 손가락 좌우: 다음/이전 곡
            if abs(scrollAccum.width) > abs(scrollAccum.height) * 1.5, vm.displayed?.kind == .media {
                let contentDX = natural ? scrollAccum.width : -scrollAccum.width
                if abs(contentDX) > 50 { vm.shared.onMediaSwipe?(contentDX < 0) }
                return
            }
            guard abs(scrollAccum.height) > abs(scrollAccum.width) * 1.5 else { return }
            let fingerUp = natural ? -scrollAccum.height : scrollAccum.height
            let center = vm.center
            // 상세(확장) 알림 위로 올리기: 알림만 올려 보낸다 (전화 수신이면 거절이 아니라 접기)
            if fingerUp > 30, vm.state == .detail, center.transient != nil {
                if let handler = vm.shared.onDetailSwipeUp { withAnimation(vm.closeSpring) { handler() } }
                Haptics.perform()
                return
            }
            if fingerUp > 30, vm.visibleTransient == nil, vm.topPersistent != nil {
                withAnimation(vm.closeSpring) { center.setPersistentHidden(true) }
                Haptics.perform()
            } else if fingerUp < -30, center.persistentHidden {
                withAnimation(vm.openSpring) { center.setPersistentHidden(false) }
                Haptics.perform()
            }
        default:
            break
        }
    }
}
