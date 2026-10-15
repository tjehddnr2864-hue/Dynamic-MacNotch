import AppKit
import SwiftUI
import QuartzCore

// 계속 움직이는 작은 애니메이션(파형, 녹화 점, 회전 링)은 Core Animation으로 그린다.
// SwiftUI의 TimelineView·repeatForever는 매 프레임 노치 화면 전체를 다시 계산해 CPU를 계속 쓰지만,
// CA 애니메이션은 시스템 렌더 서버가 따로 돌리므로 앱 CPU를 거의 쓰지 않는다.

/// 재생 중 움직이는 오디오 파형 (막대 5개, 각기 다른 속도로 오르내림)
struct WaveformView: NSViewRepresentable {
    var playing: Bool
    var tint: Color

    func makeNSView(context: Context) -> WaveformLayerView { WaveformLayerView() }

    func updateNSView(_ v: WaveformLayerView, context: Context) {
        v.configure(playing: playing, color: NSColor(tint).cgColor)
    }
}

final class WaveformLayerView: NSView {
    private var bars: [CALayer] = []
    private var playing: Bool?
    private static let durations: [CFTimeInterval] = [0.42, 0.55, 0.36, 0.61, 0.47]
    private static let offsets: [CFTimeInterval] = [0.0, 0.21, 0.12, 0.33, 0.07]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        for _ in 0..<5 {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let n = CGFloat(bars.count), gap: CGFloat = 2
        let w = max(1.5, (bounds.width - gap * (n - 1)) / n)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(i) * (w + gap) + w / 2, y: bounds.midY)
            bar.cornerRadius = w / 2
        }
        CATransaction.commit()
    }

    func configure(playing: Bool, color: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = color }
        CATransaction.commit()
        guard playing != self.playing else { return }
        self.playing = playing
        for (i, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            if playing {
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = 0.3
                a.toValue = 1.0
                a.duration = Self.durations[i]
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.beginTime = CACurrentMediaTime() + Self.offsets[i]
                a.fillMode = .backwards
                bar.add(a, forKey: "wave")
                bar.transform = CATransform3DIdentity
            } else {
                bar.transform = CATransform3DMakeScale(1, 0.25, 1)
            }
        }
    }
}

/// 박동하는 녹화 점
struct RecordingDot: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 9, height: 9))
        v.wantsLayer = true
        let dot = CALayer()
        dot.backgroundColor = NSColor.systemRed.cgColor
        dot.frame = CGRect(x: 0, y: 0, width: 9, height: 9)
        dot.cornerRadius = 4.5
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0
        a.toValue = 0.45
        a.duration = 0.8
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(a, forKey: "pulse")
        v.layer?.addSublayer(dot)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: 9, height: 9)
    }
}

/// 진행률을 알 수 없을 때의 회전 링
struct SpinnerRing: NSViewRepresentable {
    var tint: Color

    func makeNSView(context: Context) -> SpinnerLayerView { SpinnerLayerView() }

    func updateNSView(_ v: SpinnerLayerView, context: Context) {
        v.ring.strokeColor = NSColor(tint).cgColor
    }
}

final class SpinnerLayerView: NSView {
    let ring = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = 2.4
        ring.lineCap = .round
        ring.strokeEnd = 0.7
        layer?.addSublayer(ring)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = ring.lineWidth / 2
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        CATransaction.commit()
        // 이전 애니메이션이 bounds 변경으로 지워졌으면 다시 건다
        if ring.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1
            spin.repeatCount = .infinity
            ring.add(spin, forKey: "spin")
        }
    }
}
