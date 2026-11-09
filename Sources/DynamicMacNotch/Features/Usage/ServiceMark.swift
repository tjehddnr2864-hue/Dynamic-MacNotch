import SwiftUI

/// AI 서비스 기호. 원본 로고가 아니라 서비스를 구분할 만큼 비슷한 모양을 서비스 색으로 그린다.
struct ServiceMark: View {
    var service: AIService
    var size: CGFloat

    var body: some View {
        Group {
            switch service {
            case .claude: ClaudeMark().fill(service.tint)
            case .gemini: GeminiMark().fill(service.tint)
            case .chatgpt: ChatGPTMark().stroke(service.tint, lineWidth: max(1.2, size * 0.1))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(service.name)
    }
}

/// 방사형 별 (가운데에서 뻗은 둥근 막대 10개)
private struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for i in 0..<10 {
            let ray = Path(roundedRect: CGRect(x: -r * 0.09, y: -r, width: r * 0.18, height: r * 0.8), cornerRadius: r * 0.09)
            let turn = CGAffineTransform(rotationAngle: CGFloat(i) * .pi / 5).concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            path.addPath(ray, transform: turn)
        }
        return path
    }
}

/// 네 꼭지 별 (변이 안으로 휜 반짝임)
private struct GeminiMark: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: rect.maxY), control: c)
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: rect.minY), control: c)
        path.closeSubpath()
        return path
    }
}

/// 꽃잎 고리 (둥근 꽃잎 6개를 겹쳐 돌린 매듭 모양)
private struct ChatGPTMark: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2 * 0.9
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for i in 0..<6 {
            let petal = Path(roundedRect: CGRect(x: -r * 0.3, y: -r, width: r * 0.6, height: r * 0.98), cornerRadius: r * 0.3)
            let turn = CGAffineTransform(rotationAngle: CGFloat(i) * .pi / 3).concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            path.addPath(petal, transform: turn)
        }
        return path
    }
}
