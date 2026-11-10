import AppKit
import SwiftUI

// 알림에 쓰는 작은 그림: 게이지, 자물쇠, 굴러가는 숫자, VPN·배터리 아이콘

/// 원형 게이지.
struct RingGauge: View {
    var value: Double
    var tint: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// 가로 바 게이지.
struct BarGauge: View {
    var value: Double
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(tint).frame(width: geo.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 5)
    }
}

/// 자물쇠. open이 되면 고리가 위로 튀어 오르며 왼쪽 기둥을 축으로 열린다.
struct LockGlyph: View {
    var open: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let bodyH = h * 0.55
            ZStack(alignment: .top) {
                // 고리
                Shackle()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: max(1.6, w * 0.14), lineCap: .round))
                    .frame(width: w * 0.62, height: h * 0.5)
                    // iOS 잠금해제처럼: 살짝 들린 뒤 오른쪽 기둥을 축으로 오른쪽으로 돌아가며 열린다
                    .rotation3DEffect(.degrees(open ? 180 : 0), axis: (x: 0, y: 1, z: 0),
                                      anchor: .trailing, perspective: 0.4)
                    .offset(y: open ? -h * 0.1 : 0)
                    .offset(y: h * 0.02)
                // 몸통
                RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                    .fill(Color.white)
                    .frame(width: w, height: bodyH)
                    .offset(y: h - bodyH)
            }
            .frame(width: w, height: h, alignment: .top)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.72), value: open)
    }

    private struct Shackle: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.width / 2))
            p.addArc(center: CGPoint(x: r.midX, y: r.minY + r.width / 2), radius: r.width / 2,
                     startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            return p
        }
    }
}

/// 숫자가 바뀔 때 위로 밀려 올라가며 바뀌는 텍스트.
/// SwiftUI의 `.contentTransition(.numericText())`는 이 macOS에서 값이 바뀔 때마다 약 1MB를 놓아주지 않아
/// (타이머·다운로드처럼 계속 바뀌는 숫자에서 메모리가 계속 늘어남) 직접 구현한 가벼운 전환으로 대체한다.
struct RollingText: View {
    var text: String
    /// 숫자가 커지면 위로, 작아지면 아래로 굴러간다. nil이면 이전 값과 비교해 자동으로 정한다.
    var up: Bool? = nil

    private final class Memory {
        var value: Double?
        var up = true
    }
    private let memory = State(initialValue: Memory())

    private var goingUp: Bool {
        if let up { return up }
        let m = memory.wrappedValue
        let digits = text.filter { $0.isNumber || $0 == "." }
        if let v = Double(digits) {
            if let old = m.value, v != old { m.up = v > old }
            m.value = v
        }
        return m.up
    }

    var body: some View {
        let rising = goingUp
        // 글자를 오른쪽 끝에서부터의 자리로 구분해, 바뀐 자리만 굴러가게 한다 (예: 46→47이면 1의 자리만)
        let chars = Array(text)
        HStack(spacing: 0) {
            // 식별자 = 오른쪽 끝에서부터의 자리 (자릿수가 바뀌어도 1의 자리는 1의 자리로 유지)
            ForEach(Array((0..<chars.count).reversed()), id: \.self) { place in
                RollingDigit(char: chars[chars.count - 1 - place], rising: rising)
            }
        }
        .clipped()
        .animation(.spring(duration: 0.3, bounce: 0.1), value: text)
    }
}

/// 한 자리 글자. 글자가 바뀔 때만 위/아래로 굴러간다.
private struct RollingDigit: View {
    let char: Character
    let rising: Bool

    var body: some View {
        ZStack {
            Text(String(char))
                .id(char)
                .transition(.asymmetric(
                    insertion: .move(edge: rising ? .bottom : .top).combined(with: .opacity),
                    removal: .move(edge: rising ? .top : .bottom).combined(with: .opacity)
                ))
        }
        .clipped()
    }
}

/// 배터리 알림 아이콘 정보 (잔량 0~1, 충전 중이면 번개)
/// VPN 아이콘 (시스템 설정의 VPN과 같은 모양): 지구본 아래 기둥, 작은 점, 가로선
struct VPNGlyph: View {
    /// 이 값을 심볼로 쓰는 알림은 이 아이콘으로 그린다
    static let symbol = "network"
    var size: CGFloat

    var body: some View {
        let line = max(1.2, size * 0.07)
        VStack(spacing: 0) {
            Image(systemName: Self.symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .fontWeight(.medium)
                .frame(width: size * 0.72, height: size * 0.72)
            Rectangle().frame(width: line, height: size * 0.08)
            ZStack {
                Capsule().frame(width: size * 0.9, height: line)
                Circle().frame(width: size * 0.2, height: size * 0.2)
            }
            .frame(height: size * 0.2)
        }
        .frame(width: size, height: size)
    }
}

/// 배터리 아이콘 안에 퍼센트 숫자를 겹친 모양 (충전 중 상시 표시 왼쪽)
struct BatteryPercentGlyph: View {
    var level: Double
    var tint: Color
    var width: CGFloat

    var body: some View {
        BatteryGlyph(info: BatteryGlyphInfo(level: level, charging: false), tint: tint.opacity(0.75), width: width)
            .overlay(alignment: .center) {
                Text("\(Int((level * 100).rounded()))")
                    .font(.system(size: width * 0.34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 0.8)
                    .offset(x: -width * 0.04)   // 오른쪽 단자를 뺀 몸통 가운데
            }
    }
}

struct BatteryGlyphInfo: Equatable {
    var level: Double
    var charging: Bool
}

/// 충전·부족·완충 알림이 함께 쓰는 배터리 아이콘. 크기·모양이 같고 채움 양과 색만 다르다.
/// 충전 중에는 배터리 위에 번개를 겹친다(번개 둘레는 검은 테두리로 떼어 보이게).
struct BatteryGlyph: View {
    var info: BatteryGlyphInfo
    var tint: Color
    /// 아이콘 가로 길이 (세로는 가로의 0.5)
    var width: CGFloat

    var body: some View {
        let h = width * 0.5
        let bodyW = width - width * 0.08
        let stroke = max(1.2, width * 0.06)
        let inset = stroke + max(1, width * 0.05)
        let corner = h * 0.3
        let fillW = max(h * 0.18, (bodyW - inset * 2) * CGFloat(min(max(info.level, 0), 1)))
        HStack(spacing: width * 0.025) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.45), lineWidth: stroke)
                RoundedRectangle(cornerRadius: max(1, corner - inset * 0.6), style: .continuous)
                    .fill(tint)
                    .frame(width: fillW, height: h - inset * 2)
                    .padding(.leading, inset)
            }
            .frame(width: bodyW, height: h)
            .overlay {
                if info.charging {
                    ZStack {
                        // 번개 둘레를 검게 비워 채움과 구분
                        Image(systemName: "bolt.fill")
                            .font(.system(size: h * 1.02, weight: .black))
                            .foregroundStyle(.black)
                        Image(systemName: "bolt.fill")
                            .font(.system(size: h * 0.82, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            RoundedRectangle(cornerRadius: width * 0.03, style: .continuous)
                .fill(Color.white.opacity(0.45))
                .frame(width: width * 0.055, height: h * 0.36)
        }
        .frame(width: width, height: h)
    }
}
