import AppKit
import SwiftUI

/// 메뉴바 위, 모든 Space·전체화면 앱 위에 떠 있는 테두리 없는 패널 (가이드라인 2.1).
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: NotchGeometry.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // isFloatingPanel은 level을 .floating으로 되돌리므로 먼저 설정한다.
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
    }

    /// 키보드 입력이 필요한 칸(타이머 숫자 입력)을 눌렀을 때만 키 창이 된다 (becomesKeyOnlyIfNeeded).
    /// 일반 클릭은 다른 앱의 키보드 포커스를 가져오지 않는다.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 편집 단축키(⌘X·C·V·A·Z, ⇧⌘Z)를 입력 칸에 직접 보낸다 (메모·타이머 입력).
    /// 메뉴가 없고, 노치 창이 키보드를 받는 동안에도 앱이 '활성'이 아니라 메뉴 단축키 단계를 거치지 않으므로
    /// 창이 키 이벤트를 받는 단계에서 처리한다.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleEditingShortcut(event) { return }
        super.sendEvent(event)
    }

    private func handleEditingShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let responder = firstResponder, responder is NSText else { return false }
        let action: Selector
        // 키 위치로 판단한다 (한글 입력 상태에서도 ⌘C 등이 동작하게)
        switch (event.keyCode, flags.contains(.shift)) {
        case (7, false): action = #selector(NSText.cut(_:))        // X
        case (8, false): action = #selector(NSText.copy(_:))       // C
        case (9, false): action = #selector(NSText.paste(_:))      // V
        case (0, false): action = #selector(NSText.selectAll(_:))  // A
        case (6, false): action = Selector(("undo:"))              // Z
        case (6, true): action = Selector(("redo:"))               // ⇧Z
        default: return false
        }
        return responder.tryToPerform(action, with: self)
    }

    /// 메뉴바 영역 위에 놓을 수 있도록 시스템의 프레임 보정을 막는다.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

protocol NotchGestureDelegate: AnyObject {
    func pointerDown(_ event: NSEvent)
    func pointerDragged(_ event: NSEvent)
    func pointerUp(_ event: NSEvent)
    func pressure(_ event: NSEvent)
    func secondaryClick(_ event: NSEvent, in view: NSView)
    func scroll(_ event: NSEvent)
}

/// SwiftUI를 호스팅하면서 원시 마우스·압력 이벤트를 제스처 처리기로 넘긴다.
/// 이벤트는 항상 super에도 전달해 확장 화면의 SwiftUI 버튼이 동작하게 한다.
final class NotchHostingView: NSHostingView<NotchRootView> {
    weak var gestureDelegate: NotchGestureDelegate?

    required init(rootView: NotchRootView) {
        super.init(rootView: rootView)
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        gestureDelegate?.pointerDown(event)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        gestureDelegate?.pointerDragged(event)
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        gestureDelegate?.pointerUp(event)
    }

    override func pressureChange(with event: NSEvent) {
        gestureDelegate?.pressure(event)
        super.pressureChange(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        gestureDelegate?.secondaryClick(event, in: self)
    }

    override func scrollWheel(with event: NSEvent) {
        gestureDelegate?.scroll(event)
        super.scrollWheel(with: event)
    }
}

enum Haptics {
    static func perform() {
        switch AppSettings.shared.hapticStrength {
        case .off: return
        case .weak: NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case .strong: NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }
}
