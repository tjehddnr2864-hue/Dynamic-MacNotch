import SwiftUI

/// 자원 사용량 확장 화면 (홈 페이지와 상시 항목 팝업이 함께 쓴다).
/// CPU·GPU·네트워크는 값과 최근 60회 그래프, 메모리는 앱·압축·와이어드 막대와 사용률·스왑.
/// 이 화면이 보이는 동안만 네 지표를 읽는다 (NotchHub가 수요를 낸다).
struct ResourcePage: View {
    @ObservedObject private var readings = ResourceSampler.shared.readings

    var body: some View {
        let s = readings.snapshot
        VStack(spacing: 8) {
            HStack {
                Text(T("자원 사용량", "Resource Usage"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            HStack(spacing: 10) {
                graphCell("CPU", value: s.cpu.map { "\($0)%" }, values: readings.history[.cpu] ?? [], maxValue: 100, tint: .mint)
                graphCell("GPU", value: s.gpu.map { "\($0)%" } ?? (ResourceSampler.shared.gpuAvailable ? nil : T("읽을 수 없음", "Unavailable")),
                          values: readings.history[.gpu] ?? [], maxValue: 100, tint: .teal)
            }
            networkCell(s.net)
            memoryCell(s.mem)
        }
        .padding(.top, 2)
    }

    // MARK: 칸

    private func header(_ title: String, _ value: String?) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 0)
            Text(value ?? "–")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private func graphCell(_ title: String, value: String?, values: [Double], maxValue: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            header(title, value)
            Sparkline(values: values, maxValue: maxValue)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                .background(Sparkline(values: values, maxValue: maxValue, closed: true).fill(tint.opacity(0.15)))
                .frame(height: 20)
                .background(alignment: .bottom) { Self.baseline }
        }
        .frame(maxWidth: .infinity)
    }

    private func networkCell(_ net: NetworkReading?) -> some View {
        let received = readings.history[.net] ?? [], sent = readings.sentHistory
        let top = max(1000, (received + sent).max() ?? 0)
        return VStack(alignment: .leading, spacing: 3) {
            header(T("네트워크", "Network"), net.map { "↓ \(Self.rate($0.received))   ↑ \(Self.rate($0.sent))" })
            ZStack {
                Sparkline(values: received, maxValue: top).stroke(Color.blue, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                Sparkline(values: sent, maxValue: top).stroke(Color.orange.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
            .frame(height: 18)
            .background(alignment: .bottom) { Self.baseline }
        }
    }

    /// 그래프 바닥선 (기록이 아직 적어도 그래프 자리를 알 수 있게)
    private static var baseline: some View { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }

    private func memoryCell(_ mem: MemoryReading?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            header(T("메모리", "Memory"), mem.map { "\(Int($0.percent.rounded()))%" })
            GeometryReader { geo in
                let total = Double(max(mem?.total ?? 1, 1))
                HStack(spacing: 0) {
                    ForEach(Self.memoryParts(mem), id: \.label) { part in
                        part.color.frame(width: geo.size.width * Double(part.bytes) / total)
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
            }
            .frame(height: 6)
            HStack(spacing: 8) {
                ForEach(Self.memoryParts(mem), id: \.label) { part in
                    legend(part.color, part.label, part.bytes)
                }
                legend(nil, T("스왑", "Swap"), mem?.swap ?? 0)
                Spacer(minLength: 0)
            }
        }
    }

    private func legend(_ color: Color?, _ label: String, _ bytes: UInt64) -> some View {
        HStack(spacing: 3) {
            if let color { Circle().fill(color).frame(width: 5, height: 5) }
            Text("\(label) \(Self.gigabytes(bytes))")
                .font(.system(size: 8.5)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: 글자

    private static func memoryParts(_ mem: MemoryReading?) -> [(label: String, bytes: UInt64, color: Color)] {
        [(T("앱", "App"), mem?.app ?? 0, .mint),
         (T("압축", "Compressed"), mem?.compressed ?? 0, .yellow),
         (T("와이어드", "Wired"), mem?.wired ?? 0, .purple)]
    }

    /// 활동 상태 보기와 같은 단위 (1GB = 1024³ 바이트)
    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1fGB", Double(bytes) / 1_073_741_824)
    }

    /// 12.3 MB/s · 850 KB/s
    static func rate(_ bytesPerSecond: UInt64) -> String {
        let v = Double(bytesPerSecond)
        if v >= 1e9 { return String(format: "%.1f GB/s", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1f MB/s", v / 1e6) }
        return "\(Int((v / 1e3).rounded())) KB/s"
    }
}

/// 최근 값 그래프. 오른쪽 끝이 최신 값이고, 기록이 적으면 오른쪽에 붙여 그린다.
private struct Sparkline: Shape {
    var values: [Double]
    var maxValue: Double
    var closed = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, maxValue > 0 else { return path }
        let step = rect.width / CGFloat(ResourceReadings.historyLength - 1)
        let start = rect.maxX - step * CGFloat(values.count - 1)
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: start + step * CGFloat(i), y: rect.maxY - rect.height * CGFloat(min(values[i], maxValue) / maxValue))
        }
        path.move(to: point(0))
        for i in 1..<values.count { path.addLine(to: point(i)) }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: start, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}
