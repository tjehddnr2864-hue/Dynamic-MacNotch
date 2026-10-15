// NotchIsland 앱 아이콘 생성기: swift Resources/Icon/make_icon.swift <출력 png> <크기>
import AppKit

let out = CommandLine.arguments[1]
let size = CGFloat(Double(CommandLine.arguments[2]) ?? 1024)
let s = size / 1024

let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS 아이콘 격자: 824pt 둥근 사각형, 바깥 여백 100pt
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    // 그림자
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); squircle.fill()
    ctx.restoreGState()

    // 배경: 화면 같은 파랑→보라 그라데이션
    ctx.saveGState()
    squircle.addClip()
    NSGradient(colors: [NSColor(red: 0.30, green: 0.56, blue: 1.00, alpha: 1),
                        NSColor(red: 0.47, green: 0.36, blue: 0.98, alpha: 1)])!
        .draw(in: body, angle: -60)
    // 위쪽 빛
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.55), angle: 90)

    // 노치: 화면 위 가장자리에 붙은 검은 도형 (위쪽 오목 모서리 + 아래 둥근 모서리)
    let nw = 470 * s, nh = 150 * s, t = 34 * s, b = 70 * s
    let x0 = body.midX - nw / 2, y0 = body.minY
    let p = NSBezierPath()
    p.move(to: CGPoint(x: x0 - t, y: y0))
    p.curve(to: CGPoint(x: x0, y: y0 + t), controlPoint1: CGPoint(x: x0, y: y0), controlPoint2: CGPoint(x: x0, y: y0))
    p.line(to: CGPoint(x: x0, y: y0 + nh - b))
    p.curve(to: CGPoint(x: x0 + b, y: y0 + nh), controlPoint1: CGPoint(x: x0, y: y0 + nh), controlPoint2: CGPoint(x: x0, y: y0 + nh))
    p.line(to: CGPoint(x: x0 + nw - b, y: y0 + nh))
    p.curve(to: CGPoint(x: x0 + nw, y: y0 + nh - b), controlPoint1: CGPoint(x: x0 + nw, y: y0 + nh), controlPoint2: CGPoint(x: x0 + nw, y: y0 + nh))
    p.line(to: CGPoint(x: x0 + nw, y: y0 + t))
    p.curve(to: CGPoint(x: x0 + nw + t, y: y0), controlPoint1: CGPoint(x: x0 + nw, y: y0), controlPoint2: CGPoint(x: x0 + nw, y: y0))
    p.close()
    NSColor.black.setFill(); p.fill()

    // 노치 안: 왼쪽 초록 점, 오른쪽 파형 막대 (살아 있는 노치)
    let cy = y0 + nh * 0.52
    NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: x0 + 62 * s, y: cy - 24 * s, width: 48 * s, height: 48 * s)).fill()
    NSColor.white.setFill()
    let heights: [CGFloat] = [34, 64, 46, 78, 40]
    for (i, h) in heights.enumerated() {
        let bx = x0 + nw - 175 * s + CGFloat(i) * 24 * s
        NSBezierPath(roundedRect: CGRect(x: bx, y: cy - h * s / 2, width: 13 * s, height: h * s), xRadius: 6.5 * s, yRadius: 6.5 * s).fill()
    }
    ctx.restoreGState()
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
