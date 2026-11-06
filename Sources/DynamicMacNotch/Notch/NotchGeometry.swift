import AppKit

enum NotchGeometry {
    /// 노치 패널 윈도우 고정 크기. 내부 SwiftUI 도형만 애니메이션한다 (가이드라인 2.1).
    static let panelSize = CGSize(width: 720, height: 300)

    /// 화면 좌표계 기준 노치 사각형. 노치가 없는 화면은 메뉴바 높이의 가상 노치를 만든다.
    static func notchRect(on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let top = screen.safeAreaInsets.top
        if top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            return CGRect(x: frame.minX + left.width, y: frame.maxY - top, width: width, height: top)
        }
        let menuBar = max(24, frame.maxY - screen.visibleFrame.maxY)
        let width: CGFloat = 190
        return CGRect(x: frame.midX - width / 2, y: frame.maxY - menuBar, width: width, height: menuBar)
    }

    static func hasPhysicalNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }
}
