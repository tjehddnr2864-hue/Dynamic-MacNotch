// 자원 읽기 비용·가용성 측정 (docs/RESOURCE_GUIDELINE.md §2).
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
    print(String(format: "%-34@ %8.1f us/call  %@", name as NSString, us, last))
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
func disk() -> String {
    let url = URL(fileURLWithPath: "/")
    guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]),
          let total = v.volumeTotalCapacity, let imp = v.volumeAvailableCapacityForImportantUsage, let avail = v.volumeAvailableCapacity else { return "fail" }
    return String(format: "total=%.0fGB important-free=%.1fGB plain-free=%.1fGB used(imp)=%.0f%%", Double(total) / 1e9, Double(imp) / 1e9, Double(avail) / 1e9, (1 - Double(imp) / Double(total)) * 100)
}
func statfsDisk() -> String {
    var s = statfs(); guard statfs("/System/Volumes/Data", &s) == 0 else { return "fail" }
    let total = Double(s.f_blocks) * Double(s.f_bsize), free = Double(s.f_bavail) * Double(s.f_bsize)
    return String(format: "data vol free=%.1fGB of %.0fGB", free / 1e9, total / 1e9)
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
bench("DISK resourceValues(/)", 200, disk)
bench("DISK statfs(Data)", 500, statfsDisk)
bench("GPU IOAccelerator stats", 100, gpu)
