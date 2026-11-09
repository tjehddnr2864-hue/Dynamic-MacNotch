// 자원 읽기 비용·가용성 측정: CPU·메모리·스왑·네트워크·GPU (docs/RESOURCE_GUIDELINE.md §2).
// 실행: swiftc -O scripts/resource-bench.swift -o /tmp/resource-bench && /tmp/resource-bench

import Foundation
import IOKit
import Darwin

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func bench(_ name: String, _ n: Int = 200, _ f: () -> String) {
    _ = f()
    let t0 = now(); var last = ""
    for _ in 0..<n { last = f() }
    let us = Double(now() - t0) / Double(n) / 1000
    print(String(format: "%-30@ %8.1f us/call  %@", name as NSString, us, last))
}
var prevTicks: [UInt32] = []
func cpu() -> String {
    var cpuCount: natural_t = 0, info: processor_info_array_t?, infoCount: mach_msg_type_number_t = 0
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info else { return "fail" }
    var ticks: [UInt32] = []
    for i in 0..<Int(cpuCount) { for s in 0..<4 { ticks.append(UInt32(bitPattern: info[i * 4 + s])) } }
    vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
    defer { prevTicks = ticks }
    guard prevTicks.count == ticks.count else { return "cores=\(cpuCount)" }
    var busy: UInt64 = 0, total: UInt64 = 0
    for i in 0..<Int(cpuCount) {
        let d = (0..<4).map { UInt64(ticks[i * 4 + $0] &- prevTicks[i * 4 + $0]) }
        busy += d[0] + d[1] + d[3]; total += d.reduce(0, +)
    }
    return String(format: "cores=%d busy=%.1f%%", cpuCount, total == 0 ? 0 : Double(busy) / Double(total) * 100)
}
func mem() -> String {
    var s = vm_statistics64(), count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &s) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
    guard kr == KERN_SUCCESS else { return "fail" }
    var total: UInt64 = 0, size = MemoryLayout<UInt64>.size; sysctlbyname("hw.memsize", &total, &size, nil, 0)
    let page = UInt64(vm_kernel_page_size)
    let used = (UInt64(s.active_count) + UInt64(s.wire_count) + UInt64(s.compressor_page_count)) * page
    return String(format: "used=%.1fGB of %.0fGB (%.0f%%) free=%.1fGB", Double(used) / 1e9, Double(total) / 1e9, Double(used) / Double(total) * 100, Double(UInt64(s.free_count) * page) / 1e9)
}
let skip = ["lo", "utun", "awdl", "llw", "bridge", "anpi", "gif", "stf", "ap", "ipsec"]
func physical(_ name: String) -> Bool { !skip.contains { name.hasPrefix($0) } }
// 1) getifaddrs (32비트 카운터)
func viaGetifaddrs() -> String {
    var head: UnsafeMutablePointer<ifaddrs>?; guard getifaddrs(&head) == 0 else { return "fail" }; defer { freeifaddrs(head) }
    var rx: UInt64 = 0, tx: UInt64 = 0, names = Set<String>()
    var p = head
    while let a = p { defer { p = a.pointee.ifa_next }
        guard let addr = a.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let d = a.pointee.ifa_data else { continue }
        let name = String(cString: a.pointee.ifa_name); guard physical(name) else { continue }
        let data = d.assumingMemoryBound(to: if_data.self).pointee
        rx += UInt64(data.ifi_ibytes); tx += UInt64(data.ifi_obytes); names.insert(name) }
    return "rx=\(rx/1_000_000)MB tx=\(tx/1_000_000)MB \(names.sorted())"
}
// 2) sysctl NET_RT_IFLIST2 (64비트 카운터)
func viaIflist2() -> String {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]; var len = 0
    guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return "fail" }
    var buf = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return "fail" }
    var rx: UInt64 = 0, tx: UInt64 = 0, off = 0, count = 0
    return buf.withUnsafeBytes { raw -> String in
        while off + MemoryLayout<if_msghdr>.size <= len {
            let h = raw.load(fromByteOffset: off, as: if_msghdr.self)
            if Int32(h.ifm_type) == RTM_IFINFO2 {
                let m = raw.load(fromByteOffset: off, as: if_msghdr2.self)
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE)); if_indextoname(UInt32(m.ifm_index), &name)
                if physical(String(cString: name)) { rx += m.ifm_data.ifi_ibytes; tx += m.ifm_data.ifi_obytes; count += 1 }
            }
            off += Int(h.ifm_msglen)
        }
        return "rx=\(rx/1_000_000)MB tx=\(tx/1_000_000)MB ifaces=\(count) buf=\(len)B"
    }
}
func swap() -> String {
    var s = xsw_usage(), size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &s, &size, nil, 0) == 0 else { return "fail" }
    return String(format: "swap used=%.2fGB total=%.2fGB", Double(s.xsu_used) / 1e9, Double(s.xsu_total) / 1e9)
}
func gpu() -> String {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return "no service" }
    defer { IOObjectRelease(iter) }
    var out = ""
    var e = IOIteratorNext(iter)
    while e != 0 {
        var props: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS, let d = props?.takeRetainedValue() as? [String: Any],
           let stats = d["PerformanceStatistics"] as? [String: Any] {
            let u = stats["Device Utilization %"] ?? stats["GPU Activity(%)"] ?? "?"
            out += "util=\(u) keys=\(stats.keys.filter { $0.contains("Util") || $0.contains("Activity") }.sorted())"
        }
        IOObjectRelease(e); e = IOIteratorNext(iter)
    }
    return out.isEmpty ? "no stats" : out
}
print("pid \(getpid())")
bench("CPU host_processor_info", 500, cpu)
bench("MEM host_statistics64", 500, mem)
bench("SWAP vm.swapusage", 2000, swap)
bench("NET getifaddrs (32bit)", 500, viaGetifaddrs)
bench("NET sysctl IFLIST2 (64bit)", 500, viaIflist2)
bench("GPU IOAccelerator stats", 100, gpu)
