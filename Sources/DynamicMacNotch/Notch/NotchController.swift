import AppKit
import SwiftUI
import Combine

/// 노치 패널 배치, 마우스 통과/호버 판정, 제스처 매핑을 맡는다 (가이드라인 4장).
final class NotchController: NotchGestureDelegate {
    let panel = NotchPanel()
    /// 잠금화면 전용 노치 창. 같은 뷰를 그리며 SkyLight 전용 Space(잠금화면 위)에 들어가 있고, 잠금 중에만 보인다.
    /// 평소 노치(panel)는 일반 레이어에 두어 파일 드래그·드롭이 정상 동작하게 한다.
    let lockPanel = NotchPanel()
    private(set) var lockPanelReady = false
    private var lockRootView: NotchRootView?
    private var lockPanelFrame = CGRect.zero
    let vm: NotchViewModel
    private let hostingView: NotchHostingView
    private let settings = AppSettings.shared
    private let menuProvider: () -> NSMenu
    /// 짧은 클릭: (표시 중인 활동, 노치 가운데보다 왼쪽을 눌렀는지)
    private let clickHandler: (NotchActivity?, Bool) -> Void

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

    init(vm: NotchViewModel,
         rootView: NotchRootView,
         menuProvider: @escaping () -> NSMenu,
         clickHandler: @escaping (NotchActivity?, Bool) -> Void) {
        self.vm = vm
        self.menuProvider = menuProvider
        self.clickHandler = clickHandler
        hostingView = NotchHostingView(rootView: rootView)
        hostingView.gestureDelegate = self
        panel.contentView = hostingView
        lockRootView = rootView   // 잠금화면 노치 창은 잠겨 있는 동안에만 이 뷰를 붙여 그린다
        lockPanel.ignoresMouseEvents = true

        reposition()
        panel.orderFrontRegardless()
        installMonitors()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
        settings.$displayTarget
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reposition() } }
            .store(in: &cancellables)
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
        if hidden {
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
        lockPanel.contentView?.needsLayout = true
        lockPanel.contentView?.display()
    }

    // MARK: - 배치

    func reposition() {
        guard let screen = NotchGeometry.targetScreen(for: settings.displayTarget) else { return }
        let notch = NotchGeometry.notchRect(on: screen)
        vm.notchSize = notch.size
        vm.hasPhysicalNotch = NotchGeometry.hasPhysicalNotch(screen)
        let size = NotchGeometry.panelSize
        let frame = CGRect(x: notch.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        lockPanelFrame = frame
        if lockPanel.alphaValue > 0 { lockPanel.setFrame(frame, display: true) }
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
        // 바깥 클릭 → 확장 닫기
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, self.vm.isExpanded else { return }
            if !self.interactiveRect.contains(NSEvent.mouseLocation) { self.collapse() }
        }) {
            monitors.append(m)
        }
    }

    private func checkFileDrag() {
        guard !vm.isFileDragging else { return }
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

    private func updateHover() {
        let loc = NSEvent.mouseLocation
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
        vm.center.paused = inside

        hoverOpenWork?.cancel()
        if inside, settings.hoverToOpen, !vm.isExpanded {
            let work = DispatchWorkItem { [weak self] in self?.expand(haptic: false) }
            hoverOpenWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    // MARK: - 제스처

    private func expand(haptic: Bool) {
        guard !isLocked(), !vm.isExpanded, Date().timeIntervalSince(lastCollapse) > 0.3 else { return }
        // 알림은 확장 화면 대신 앱이 처리한다 (컴팩트 → 상세 카드, 상세 → 반응 없음)
        if let decide = vm.longPressShouldExpand, !decide(vm.center.displayed) {
            vm.endPress()
            return
        }
        let page: ExpandedPage = vm.center.displayed.map { .activity($0.kind) } ?? .home
        vm.expand(page: page)
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

    func pointerDown(_ event: NSEvent) {
        guard !vm.isExpanded else { return }
        pressFired = false
        pressOrigin = NSEvent.mouseLocation
        // 상세 알림처럼 길게누르기가 없는 경우: 누름 반응·길게누르기 없이 클릭만 받는다
        guard vm.allowsPressFeedback?(vm.center.displayed) ?? true else { return }
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
            clickHandler(vm.center.displayed, leftSide)
        }
    }

    func pressure(_ event: NSEvent) {
        guard settings.forceTouchEnabled, !vm.isExpanded, pressOrigin != nil else { return }
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
               vm.verticalScrollHandler?(fingerDY) == true {
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
                vm.verticalScrollEnded?()
                return
            }
            let fingerUp = natural ? -scrollAccum.height : scrollAccum.height
            let contentDX = natural ? scrollAccum.width : -scrollAccum.width
            if abs(scrollAccum.height) > abs(scrollAccum.width), fingerUp > 40 {
                vm.cancelDrag()
                collapse()   // 두 손가락으로 위로 쓸어 올림 → 닫기
            } else if abs(contentDX) > 50 {
                vm.switchExpandedPage(forward: contentDX < 0)
            } else {
                vm.cancelDrag()
            }
        default:
            break
        }
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
            guard abs(scrollAccum.height) > abs(scrollAccum.width) * 1.5 else { return }
            let fingerUp = natural ? -scrollAccum.height : scrollAccum.height
            let center = vm.center
            // 상세(확장) 알림 위로 올리기: 알림만 올려 보낸다 (전화 수신이면 거절이 아니라 접기)
            if fingerUp > 30, vm.state == .detail, center.transient != nil {
                if let handler = vm.onDetailSwipeUp { withAnimation(vm.closeSpring) { handler() } }
                Haptics.perform()
                return
            }
            if fingerUp > 30, center.transient == nil, center.topPersistent != nil {
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
