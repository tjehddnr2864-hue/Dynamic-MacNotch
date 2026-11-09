import Combine
import Darwin
import Foundation
import IOKit
import SwiftUI

// 자원 사용량(CPU·GPU·메모리·네트워크) 측정. 규칙은 docs/RESOURCE_GUIDELINE.md §2·§4.

/// 메모리 (바이트). 사용 = 앱 + 와이어드 + 압축 (활동 상태 보기의 '사용한 메모리')
struct MemoryReading: Equatable {
    var app: UInt64, wired: UInt64, compressed: UInt64, swap: UInt64, total: UInt64
    var used: UInt64 { app + wired + compressed }
    var percent: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 }
}

/// 네트워크 속도 (바이트/초)
struct NetworkReading: Equatable {
    var received: UInt64, sent: UInt64
}

/// 최신 값. 노치 전체가 아니라 이 객체를 관찰하는 작은 뷰만 다시 그려진다.
/// 값은 보이는 단위로 반올림해 두어 같으면 알리지 않는다.
struct ResourceSnapshot: Equatable {
    var cpu: Int?
    var gpu: Int?
    var mem: MemoryReading?
    var net: NetworkReading?
}

final class ResourceReadings: ObservableObject {
    @Published fileprivate(set) var snapshot = ResourceSnapshot()
    /// 그래프용 최근 기록 (CPU·GPU %, 네트워크 받기·보내기 바이트/초). 길이가 정해져 있어 늘지 않는다.
    fileprivate(set) var history: [MonitorMetric: [Double]] = [:]
    fileprivate(set) var sentHistory: [Double] = []
    static let historyLength = 60

    fileprivate func push(_ value: Double, to metric: MonitorMetric) {
        var list = history[metric, default: []]
        list.append(value)
        if list.count > Self.historyLength { list.removeFirst(list.count - Self.historyLength) }
        history[metric] = list
    }

    fileprivate func pushSent(_ value: Double) {
        sentHistory.append(value)
        if sentHistory.count > Self.historyLength { sentHistory.removeFirst(sentHistory.count - Self.historyLength) }
    }
}

/// 수요가 있는 지표만, 수요가 있는 동안만 타이머 하나로 읽는다. 수요가 없으면 타이머도 없다.
final class ResourceSampler {
    static let shared = ResourceSampler()

    /// 수요를 낸 곳: 노치 칸, 확장 화면, 홈 페이지 (디스플레이 UUID별)
    enum Owner: Hashable {
        case compact(String), expanded(String), page(String)
        #if DEV
        case dev
        #endif
    }

    let readings = ResourceReadings()
    private var demand: [Owner: Set<MonitorMetric>] = [:]
    private(set) var active = Set<MonitorMetric>()
    private var timer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()

    // 이전 샘플 (차이로 구하는 CPU·네트워크)
    private var cpuPrevious: [UInt32]?
    private var netPrevious: [String: (rx: UInt32, tx: UInt32)]?
    private var lastSample: UInt64 = 0
    private var gpuEntry: io_registry_entry_t = 0
    private var gpuFailures = 0
    /// GPU 사용률 키를 읽을 수 없는 Mac이면 false (설정에서 비활성으로 보인다)
    private(set) var gpuAvailable = true
    private(set) var ticks = 0

    private init() {
        let settings = AppSettings.shared
        settings.$resourceRefreshSeconds.map { _ in () }
            .merge(with: NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).map { _ in () })
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.restartTimer(firstAfter: nil) }
            .store(in: &cancellables)
    }

    /// 저전력 모드에서는 간격을 두 배로
    var interval: TimeInterval {
        let base = AppSettings.shared.resourceRefreshSeconds
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? base * 2 : base
    }

    var isRunning: Bool { timer != nil }

    /// 이 곳이 지금 보이는 지표. 빈 집합이면 수요를 거둔다.
    func setDemand(_ owner: Owner, _ metrics: Set<MonitorMetric>) {
        let wanted = metrics.intersection(MonitorMetric.resourceMetrics)
        if wanted.isEmpty { demand[owner] = nil } else { demand[owner] = wanted }
        let next = demand.values.reduce(into: Set<MonitorMetric>()) { $0.formUnion($1) }
        guard next != active else { return }
        let added = next.subtracting(active)
        active = next
        if active.isEmpty {
            stop()
            return
        }
        // 새로 필요해진 지표는 바로 한 번 읽고, CPU·네트워크는 0.25초 뒤의 두 번째 읽기로 첫 값을 만든다
        if !added.isEmpty {
            tick()
            restartTimer(firstAfter: added.contains(.cpu) || added.contains(.net) ? 0.25 : nil)
        }
        dropUnused()
    }

    /// 쓰지 않는 지표의 값과 기록을 버린다
    private func dropUnused() {
        var s = readings.snapshot
        if !active.contains(.cpu) { s.cpu = nil; cpuPrevious = nil; readings.history[.cpu] = nil }
        if !active.contains(.gpu) { s.gpu = nil; readings.history[.gpu] = nil }
        if !active.contains(.mem) { s.mem = nil }
        if !active.contains(.net) { s.net = nil; netPrevious = nil; readings.history[.net] = nil; readings.sentHistory = [] }
        if s != readings.snapshot { readings.snapshot = s }
    }

    private func restartTimer(firstAfter first: TimeInterval?) {
        guard !active.isEmpty else { return }
        timer?.cancel()
        let interval = self.interval
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + (first ?? interval), repeating: interval, leeway: .milliseconds(Int(interval * 150)))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// 측정을 멈추고 이전 샘플·값·기록을 모두 버린다
    private func stop() {
        timer?.cancel()
        timer = nil
        cpuPrevious = nil
        netPrevious = nil
        lastSample = 0
        readings.snapshot = ResourceSnapshot()
        readings.history = [:]
        readings.sentHistory = []
        if gpuEntry != 0 { IOObjectRelease(gpuEntry); gpuEntry = 0 }
        MemoryTrim.soon()
    }

    /// 메모리 지킴이가 부른다: 그래프 기록만 비운다 (다시 쌓인다)
    func compact() {
        readings.history = [:]
        readings.sentHistory = []
    }

    // MARK: - 한 번 읽기

    private func tick() {
        autoreleasepool {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            // 잠자기 등으로 간격의 3배를 넘게 비었으면 차이 값을 버리고 다시 시작한다
            if lastSample != 0, Double(now - lastSample) / 1e9 > interval * 3 {
                cpuPrevious = nil
                netPrevious = nil
            }
            let elapsed = lastSample == 0 ? 0 : Double(now - lastSample) / 1e9
            lastSample = now
            ticks += 1

            var s = readings.snapshot
            if active.contains(.cpu) {
                s.cpu = readCPU()
                if let v = s.cpu { readings.push(Double(v), to: .cpu) }
            }
            if active.contains(.gpu), gpuAvailable {
                s.gpu = readGPU()
                if let v = s.gpu { readings.push(Double(v), to: .gpu) }
            }
            if active.contains(.mem) { s.mem = readMemory() }
            if active.contains(.net) {
                s.net = readNetwork(elapsed: elapsed)
                if let n = s.net {
                    readings.push(Double(n.received), to: .net)
                    readings.pushSent(Double(n.sent))
                }
            }
            if s != readings.snapshot { readings.snapshot = s }
        }
    }

    /// 전체 코어의 (user + system + nice) ÷ 전체, 이전 읽기와의 차이
    private func readCPU() -> Int? {
        var count: natural_t = 0, info: processor_info_array_t?, infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        let ticks = (0..<Int(count) * Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[$0]) }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        defer { cpuPrevious = ticks }
        guard let previous = cpuPrevious, previous.count == ticks.count else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            let d = (0..<Int(CPU_STATE_MAX)).map { UInt64(ticks[base + $0] &- previous[base + $0]) }
            busy += d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_SYSTEM)] + d[Int(CPU_STATE_NICE)]
            total += d.reduce(0, +)
        }
        return total == 0 ? nil : Int((Double(busy) / Double(total) * 100).rounded())
    }

    private func readMemory() -> MemoryReading? {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var total: UInt64 = 0, size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        let page = UInt64(vm_kernel_page_size)
        // 화면에는 0.1GB 단위까지만 보이므로 그 단위로 반올림해 같으면 알리지 않는다
        func round(_ bytes: UInt64) -> UInt64 { (bytes + 50_000_000) / 100_000_000 * 100_000_000 }
        let internalPages = UInt64(s.internal_page_count), purgeable = UInt64(s.purgeable_count)
        return MemoryReading(app: round((internalPages > purgeable ? internalPages - purgeable : 0) * page),
                             wired: round(UInt64(s.wire_count) * page),
                             compressed: round(UInt64(s.compressor_page_count) * page),
                             swap: round(swap.xsu_used), total: total)
    }

    /// 겹쳐 세지 않도록 물리 인터페이스만 (VPN은 utun과 en0에 두 번 잡힌다)
    private static let skippedInterfaces = ["lo", "utun", "awdl", "llw", "bridge", "anpi", "gif", "stf", "ipsec", "ap"]

    /// 인터페이스별 32비트 카운터의 차이 (4GB마다 한 바퀴 돌아도 `&-`로 맞다)
    private func readNetwork(elapsed: Double) -> NetworkReading? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var current: [String: (rx: UInt32, tx: UInt32)] = [:]
        var p = head
        while let a = p {
            p = a.pointee.ifa_next
            guard let addr = a.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = a.pointee.ifa_data else { continue }
            let name = String(cString: a.pointee.ifa_name)
            guard !Self.skippedInterfaces.contains(where: name.hasPrefix) else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            current[name] = (d.ifi_ibytes, d.ifi_obytes)
        }
        defer { netPrevious = current }
        guard let previous = netPrevious, elapsed > 0 else { return nil }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for (name, now) in current {
            guard let before = previous[name] else { continue }   // 새로 생긴 인터페이스는 이번에 세지 않는다
            rx += UInt64(now.rx &- before.rx)
            tx += UInt64(now.tx &- before.tx)
        }
        // 1KB/s 단위로 반올림해 같으면 알리지 않는다
        func rate(_ bytes: UInt64) -> UInt64 { UInt64((Double(bytes) / elapsed / 1000).rounded()) * 1000 }
        return NetworkReading(received: rate(rx), sent: rate(tx))
    }

    /// `IOAccelerator`의 `Device Utilization %`. 3번 연달아 실패하면 이 Mac에서는 쓰지 않는다.
    private func readGPU() -> Int? {
        if gpuEntry == 0 { gpuEntry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator")) }
        guard gpuEntry != 0,
              let stats = IORegistryEntryCreateCFProperty(gpuEntry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let value = (stats["Device Utilization %"] as? NSNumber)?.intValue else {
            gpuFailures += 1
            if gpuFailures >= 3 { gpuAvailable = false }
            return nil
        }
        gpuFailures = 0
        return value
    }
}

// MARK: - 칸 하나 (라이브)

/// 노치 칸 하나에 자원 지표 하나. 이 뷰만 `ResourceReadings`를 관찰한다.
struct LiveMetricView: View {
    var metric: MonitorMetric
    var ring: Bool
    var tint: Color
    var large = false
    @ObservedObject private var readings = ResourceSampler.shared.readings

    var body: some View {
        let s = readings.snapshot
        Group {
            switch metric {
            case .cpu: UsageGlyph(label: "CPU", percent: s.cpu.map(Double.init), ring: ring, tint: tint, large: large)
            case .gpu: UsageGlyph(label: "GPU", percent: s.gpu.map(Double.init), ring: ring, tint: tint, large: large)
            case .mem: UsageGlyph(label: "MEM", percent: s.mem?.percent, ring: ring, tint: tint, large: large)
            case .net: NetworkGlyph(reading: s.net, large: large)
            case .aiPrimary, .aiSecondary: EmptyView()
            }
        }
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// 네트워크 칸: 위 보내기, 아래 받기 (짧은 단위)
struct NetworkGlyph: View {
    var reading: NetworkReading?
    var large = false

    /// 999K · 12.3M · 1.2G (B/s 생략)
    static func short(_ bytesPerSecond: UInt64) -> String {
        let v = Double(bytesPerSecond)
        if v >= 1e9 { return String(format: "%.1fG", v / 1e9) }
        if v >= 1e7 { return String(format: "%.0fM", v / 1e6) }
        if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        return "\(Int((v / 1e3).rounded()))K"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("↑ " + (reading.map { Self.short($0.sent) } ?? "–"))
            Text("↓ " + (reading.map { Self.short($0.received) } ?? "–"))
        }
        .font(.system(size: large ? 11 : 9.5, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
    }
}
