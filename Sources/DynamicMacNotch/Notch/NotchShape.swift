import SwiftUI

/// 물리 노치처럼 위쪽 모서리는 바깥으로 휘고(오목) 아래쪽 모서리는 둥근 도형.
/// 두 반경을 animatableData로 노출해 크기와 함께 모서리까지 연속으로 변형된다 (가이드라인 3.2).
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let t = min(topRadius, w / 4)
        let b = min(bottomRadius, (w - 2 * t) / 2, h - t)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.minY + h - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.minY + h),
                       control: CGPoint(x: rect.minX + t, y: rect.minY + h))
        p.addLine(to: CGPoint(x: rect.minX + w - t - b, y: rect.minY + h))
        p.addQuadCurve(to: CGPoint(x: rect.minX + w - t, y: rect.minY + h - b),
                       control: CGPoint(x: rect.minX + w - t, y: rect.minY + h))
        p.addLine(to: CGPoint(x: rect.minX + w - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.minX + w, y: rect.minY),
                       control: CGPoint(x: rect.minX + w - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// 가로 흔들림 효과 (타이머 종료 등).
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: sin(animatableData * .pi * 6) * 7, y: 0))
    }
}

/// 콘텐츠 등장/퇴장 시 블러 전환.
struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    /// 도형이 줄어들 때 새로 나타나는 내용: 제자리에서 옅게 나타나기만 한다 (바깥으로 이동하지 않음)
    static var notchContentInPlace: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurModifier(radius: 6), identity: BlurModifier(radius: 0))
                .combined(with: .opacity),
            removal: AnyTransition.scale(scale: 0.6, anchor: .top)
                .combined(with: .opacity)
                .animation(.easeOut(duration: 0.16))
        )
    }

    static var notchContent: AnyTransition {
        .asymmetric(
            // 나타날 때는 노치(위 가운데)에서 바깥으로 퍼지며: 왼쪽 요소는 왼쪽으로, 오른쪽 요소는 오른쪽으로 나온다.
            insertion: .modifier(active: BlurModifier(radius: 8), identity: BlurModifier(radius: 0))
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.45, anchor: .top)),
            // 사라지는 뷰는 마지막 위치에 머무르므로, 가운데(노치)로 오므라들며 빠르게 사라지게 한다.
            // 처음부터 빠르게 옅어지며(easeOut) 노치(위 가운데)로 오므라든다 → 줄어드는 도형 밖으로 보이지 않음
            removal: AnyTransition.scale(scale: 0.6, anchor: .top)
                .combined(with: .opacity)
                .animation(.easeOut(duration: 0.16))
        )
    }
}
