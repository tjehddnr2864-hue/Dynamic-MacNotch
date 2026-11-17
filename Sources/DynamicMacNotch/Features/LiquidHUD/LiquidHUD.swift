import AppKit
import SwiftUI

/// Liquid HUD (macOS 26 이상, 설정 → HUD → 디자인 "Liquid").
/// 음량·밝기를 노치 대신 노치 아래 Liquid Glass 알약으로 보인다.
///
/// 나오기: 노치에 보이던 항목이 들어가고(`SharedNotchState.liquidHUDActive`) → 노치 아래로 물방울이 매달렸다가
/// 떨어져 나가며 알약으로 커진다. 들어가기는 그 반대. 노치 끝의 작은 유리와 물방울을 한 `GlassEffectContainer`에 두어,
/// 가까우면 하나로 붙어 보이고 멀어지면 떨어진다 (Liquid Glass가 모양을 이어 준다).
///
/// 단계는 목표값 하나(`stage`)로만 움직이고 모든 움직임은 스프링이라, 들어가는 도중에 다시 조절해도
/// 그 자리에서 방향만 바꿔 자연스럽게 다시 나온다.
final class LiquidHUD: ObservableObject {
    static let shared = LiquidHUD()

    enum Stage: Int { case hidden, hanging, pill }

    @Published private(set) var stage: Stage = .hidden
    @Published private(set) var symbol = "speaker.wave.2.fill"
    @Published private(set) var level: Double = 0
    @Published private(set) var number: String = "0"
    /// 숫자 위에 작은 단위 (니트일 때 "nit")
    @Published private(set) var unit: String?
    @Published private(set) var notchHeight: CGFloat = 38

    /// 알약을 띄울 화면과 그 화면 노치 높이 (AppDelegate가 연결: 알림을 받는 주 노치)
    var anchor: (() -> (screen: NSScreen, notchHeight: CGFloat)?)?
    /// 노치에 보이던 항목을 들여보내고 되돌린다
    var onActiveChange: ((Bool) -> Void)?

    private var panel: NSPanel?
    private var steps: [DispatchWorkItem] = []
    private var hideWork: DispatchWorkItem?

    /// macOS 26 이상이고 설정에서 Liquid를 골랐을 때
    static var isEnabled: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return AppSettings.shared.hudDesign == .liquid
    }

    // MARK: - 크기·속도

    static let pillSize = CGSize(width: 280, height: 59)
    /// 알약 위쪽과 노치 아래 사이
    static let pillGap: CGFloat = 10
    private static let panelWidth: CGFloat = 340
    private static var panelExtra: CGFloat { pillGap + pillSize.height + 24 }

    /// 나오기: 매달리기 0.09초 뒤 떨어져 알약으로. 들어가기: 물방울로 줄어든 뒤 0.12초에 노치로.
    private static let hangDelay: TimeInterval = 0.1
    private static let retractDelay: TimeInterval = 0.12
    private static let settleAfterHide: TimeInterval = 0.16

    static let showSpring = Animation.spring(response: 0.3, dampingFraction: 0.74)
    static let hangSpring = Animation.spring(response: 0.16, dampingFraction: 0.8)
    static let hideSpring = Animation.spring(response: 0.2, dampingFraction: 0.9)

    // MARK: - 보이기·숨기기

    /// 값을 보이고, `duration` 뒤에 들어간다. 이미 나와 있으면 값만 바꾸고 시간을 다시 잰다.
    func show(symbol: String, level: Double, number: String, unit: String?, duration: TimeInterval) {
        guard let anchor = anchor?() else { return }
        place(on: anchor.screen, notchHeight: anchor.notchHeight)
        withAnimation(.spring(response: 0.18, dampingFraction: 0.9)) {
            self.symbol = symbol
            self.level = max(0, min(1, level))
            self.number = number
            self.unit = unit
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)

        guard stage != .pill || !steps.isEmpty else { return }   // 이미 나와 있음
        cancelSteps()
        onActiveChange?(true)
        panel?.orderFrontRegardless()
        if stage == .hidden {
            // 처음 나올 때만 매달리는 단계를 거친다. 들어가는 도중이면 그 자리에서 바로 알약으로 되돌아간다.
            withAnimation(Self.hangSpring) { stage = .hanging }
            after(Self.hangDelay) { [weak self] in withAnimation(Self.showSpring) { self?.stage = .pill } }
        } else {
            withAnimation(Self.showSpring) { stage = .pill }
        }
    }

    /// 지금 값만 바꾼다 (니트를 잠시 뒤 다시 읽을 때). 나와 있지 않으면 아무것도 하지 않는다.
    func update(number: String) {
        guard stage != .hidden else { return }
        self.number = number
    }

    func hide() {
        hideWork?.cancel()
        cancelSteps()
        guard stage != .hidden else { return }
        withAnimation(Self.hideSpring) { stage = .hanging }
        after(Self.retractDelay) { [weak self] in
            guard let self else { return }
            withAnimation(Self.hangSpring) { self.stage = .hidden }
            // 물방울이 노치로 들어가는 것과 함께 노치의 상시 표시가 나온다 (끝날 때까지 기다리면 잠깐 빈 노치가 보인다)
            self.onActiveChange?(false)
        }
        after(Self.retractDelay + Self.settleAfterHide) { [weak self] in
            guard let self, self.stage == .hidden else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func after(_ delay: TimeInterval, _ run: @escaping () -> Void) {
        let work = DispatchWorkItem(block: run)
        steps.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelSteps() {
        steps.forEach { $0.cancel() }
        steps.removeAll()
    }

    // MARK: - 창

    /// 노치 바로 아래를 덮는 투명한 창. 클릭은 받지 않는다.
    private func place(on screen: NSScreen, notchHeight: CGFloat) {
        if self.notchHeight != notchHeight { self.notchHeight = notchHeight }
        let size = CGSize(width: Self.panelWidth, height: notchHeight + Self.panelExtra)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        if let panel {
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            return
        }
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isFloatingPanel = true
        // 노치 창(mainMenu + 3)보다 위: 노치 끝에서 물방울이 나오는 모습이 노치 위에 그려진다
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        if #available(macOS 26.0, *) {
            p.contentView = NSHostingView(rootView: LiquidHUDView(model: self))
        }
        panel = p
    }
}

// MARK: - 그림

@available(macOS 26.0, *)
struct LiquidHUDView: View {
    @ObservedObject var model: LiquidHUD
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let stage = model.stage
        let notch = model.notchHeight
        let pill = LiquidHUD.pillSize
        // 물방울: 숨김(노치 속 작은 점) → 매달림(노치 아래 길쭉한 방울) → 알약
        let size: CGSize = switch stage {
        case .hidden: .zero   // 유리는 opacity로 숨지 않으므로 크기로 없앤다
        case .hanging: CGSize(width: 24, height: 27)
        case .pill: pill
        }
        let centerY: CGFloat = switch stage {
        case .hidden: notch - 8
        case .hanging: notch + 12
        case .pill: notch + LiquidHUD.pillGap + pill.height / 2
        }
        // 노치 끝에 붙은 작은 유리: 물방울과 가까우면 한 덩어리로 이어져 '매달린' 모습이 된다
        // 알약으로 떨어져 나가면 노치 쪽 유리는 줄어들며 사라진다 (떨어지는 순간 둘이 갈라지는 모습)
        let stub: CGSize = stage == .hanging ? CGSize(width: 32, height: 8) : .zero

        // 노치에서 나올 때는 노치처럼 검은색이었다가, 떨어져 나가며 유리로 이어서 바뀐다 (검은 덮개의 진하기가 스프링으로 변함).
        // 유리 색조(tint)는 거의 검게 되지 않아 덮개로 칠한다.
        let t = settings.hudLiquidTransparency
        let glass: Glass = t > Self.defaultTransparency ? .clear : .regular
        let dim = Self.dim(t)
        let cover = stage == .pill ? dim : 1

        GlassEffectContainer(spacing: 18) {
            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.black)
                    .frame(width: stub.width, height: stub.height)
                    .glassEffect(glass, in: Capsule())
                    .opacity(stage == .hanging ? 1 : 0)
                    .offset(y: notch - stub.height / 2)

                RoundedRectangle(cornerRadius: min(size.width, size.height) / 2, style: .continuous)
                    .fill(Color.black.opacity(cover))
                    .frame(width: size.width, height: size.height)
                    .overlay { content(onDark: dim >= 0.3).opacity(stage == .pill ? 1 : 0) }
                    .glassEffect(glass, in: RoundedRectangle(cornerRadius: min(size.width, size.height) / 2, style: .continuous))
                    .opacity(stage == .hidden ? 0 : 1)
                    .offset(y: centerY - size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 유리 투명도: 기본(70%)은 보통 유리, 낮추면 검은 덮개가 진해지고(0%에서 70%), 높이면 더 투명한 유리(clear).
    static let defaultTransparency = 0.7
    static func dim(_ t: Double) -> Double { max(0, defaultTransparency - t) }

    /// 알약 안: 왼쪽 아이콘, 오른쪽 가로 바(16칸) 또는 숫자. 좌우 여백은 같다.
    private static let inset: CGFloat = 21
    private static let iconBox: CGFloat = 27

    /// `onDark`: 덮개가 진해 배경과 상관없이 흰 글자를 쓴다 (유리의 자동 색은 어두운 덮개를 모른다)
    private func content(onDark: Bool) -> some View {
        HStack(spacing: 0) {
            Image(systemName: model.symbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(onDark ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .frame(width: Self.iconBox, height: Self.iconBox)
                .contentTransition(.symbolEffect(.replace))
            if settings.hudLiquidValue == .bar {
                Spacer(minLength: 16)
                SegmentBar(level: model.level, onDark: onDark)
                    .frame(height: 5)
            } else {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    if let unit = model.unit {
                        Text(unit).font(.system(size: 8, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    }
                    Text(model.number)
                        .font(.system(size: model.unit == nil ? 21 : 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(onDark ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                        .contentTransition(.numericText())
                }
                .frame(minWidth: Self.iconBox, alignment: .trailing)
            }
        }
        .padding(.horizontal, Self.inset)
        .frame(width: LiquidHUD.pillSize.width, height: LiquidHUD.pillSize.height)
    }
}

/// 16칸 가로 바. 칸마다 채운 만큼 밝다 (마지막 칸은 부분만).
private struct SegmentBar: View {
    var level: Double
    var onDark = false
    private static let count = 16

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2.5
            let width = (geo.size.width - gap * CGFloat(Self.count - 1)) / CGFloat(Self.count)
            HStack(spacing: gap) {
                ForEach(0..<Self.count, id: \.self) { i in
                    let fill = max(0, min(1, level * Double(Self.count) - Double(i)))
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5).fill(onDark ? AnyShapeStyle(Color.white.opacity(0.25)) : AnyShapeStyle(.tertiary))
                        RoundedRectangle(cornerRadius: 1.5).fill(onDark ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary)).frame(width: width * fill)
                    }
                    .frame(width: width)
                }
            }
        }
    }
}
