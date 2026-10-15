import AppKit
import SwiftUI
import IOBluetooth
import IOKit
import CoreBluetooth

/// 블루투스 액세서리 연결 감지와 배터리 표시 (가이드라인 5.4).
/// 좌: 기기 아이콘, 우: 배터리. 컴팩트/상세, 백분율/원형/둘 다 옵션.
final class BluetoothMonitor: NSObject {
    struct Battery: Equatable {
        var main: Int?
        var left: Int?
        var right: Int?
        var caseLevel: Int?
        /// system_profiler가 알려 준 Apple 제품 아이콘 (이름을 바꾼 AirPods 대응)
        var symbol: String? = nil

        var primary: Int? {
            if let main { return main }
            let buds = [left, right].compactMap { $0 }
            return buds.min()
        }

        var budsSummary: String? {
            guard left != nil || right != nil else { return nil }
            var parts: [String] = []
            if let left { parts.append(T("왼쪽 \(left)%", "L \(left)%")) }
            if let right { parts.append(T("오른쪽 \(right)%", "R \(right)%")) }
            if let caseLevel { parts.append(T("케이스 \(caseLevel)%", "Case \(caseLevel)%")) }
            return parts.joined(separator: " · ")
        }
    }

    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var startedAt = Date()
    private var waitTimer: Timer?
    /// 현재 표시 중인 기기 주소 (배터리 값이 늦게 오면 이 기기일 때만 갱신)
    private var shownAddress: String?

    init(center: ActivityCenter) {
        self.center = center
        super.init()
    }

    /// 블루투스 권한이 없을 때 IOBluetooth를 등록하면 권한 창을 기다리며 메인 스레드가 멈춘다.
    /// 권한이 허용된 뒤에만 등록하고, 그 전에는 3초마다 확인한다.
    func start() {
        if CBManager.authorization == .allowedAlways {
            register()
            return
        }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] timer in
            guard CBManager.authorization == .allowedAlways else { return }
            timer.invalidate()
            self?.register()
        }
        RunLoop.main.add(t, forMode: .common)
        waitTimer = t
    }

    private func register() {
        startedAt = Date()
        prefetchDeviceTypes()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceConnected(_:device:)))
    }

    /// BLE 기기(로지텍 마우스 등)는 기기 클래스를 알려 주지 않아 연결 순간 종류를 모른다.
    /// 앱 시작 때 한 번 system_profiler로 페어링된 기기 종류를 읽어 주소별로 기억해 둔다.
    private func prefetchDeviceTypes() {
        DispatchQueue.global(qos: .utility).async {
            for (address, symbol) in Self.profilerSymbols() where Self.cachedSymbol(address) == nil {
                Self.cacheSymbol(symbol, for: address)
            }
        }
    }

    static func profilerSymbols() -> [String: String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = json["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for section in sections {
            for key in ["device_connected", "device_not_connected"] {
                for entry in section[key] as? [[String: Any]] ?? [] {
                    for (name, raw) in entry {
                        guard let info = raw as? [String: Any], let address = info["device_address"] as? String else { continue }
                        let symbol = appleSymbol(vendor: info["device_vendorID"] as? String, product: info["device_productID"] as? String)
                            ?? minorTypeSymbol(info["device_minorType"] as? String)
                            ?? nameSymbol(name.lowercased())
                        if let symbol { result[normalize(address)] = symbol }
                    }
                }
            }
        }
        return result
    }

    /// 이름으로 알 수 있는 기기
    static func nameSymbol(_ name: String) -> String? {
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if name.contains("keyboard") || name.contains("키보드") { return "keyboard" }
        if name.contains("mouse") || name.contains("마우스") { return "computermouse" }
        if name.contains("iphone") { return "iphone" }
        if name.contains("ipad") { return "ipad" }
        if name.contains("controller") || name.contains("gamepad") || name.contains("dualsense") { return "gamecontroller.fill" }
        return nil
    }

    // MARK: - 연결/해제

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? UUID().uuidString
        disconnectNotifications[address]?.unregister()
        disconnectNotifications[address] = device.register(forDisconnectNotification: self,
                                                           selector: #selector(deviceDisconnected(_:device:)))
        // 앱 시작 시 이미 연결돼 있던 기기에 대한 알림은 건너뛴다.
        guard Date().timeIntervalSince(startedAt) > 3 else { return }
        // 시스템 설정 › 블루투스에 등록된(페어링된) 내 기기만 표시한다.
        guard device.isPaired() else { return }
        // iPhone·iPad(연속성·핫스팟 등으로 자주 붙었다 떨어짐)는 액세서리가 아니므로 알리지 않는다.
        guard !Self.isPhoneOrTablet(device) else { return }
        guard settings.btEnabled, !isBlocked(device) else { return }
        show(device: device, connected: true)
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? ""
        disconnectNotifications[address]?.unregister()
        disconnectNotifications[address] = nil
        // 연결 해제 시에는 팝업을 띄우지 않는다.
    }

    private func isBlocked(_ device: IOBluetoothDevice) -> Bool {
        let name = device.name ?? ""
        return AppSettings.list(settings.btBlocklist).contains { name.localizedCaseInsensitiveContains($0) }
    }

    // MARK: - 표시

    private func show(device: IOBluetoothDevice, connected: Bool) {
        let name = device.name ?? T("블루투스 기기", "Bluetooth Device")
        let address = device.addressString ?? ""
        let symbol = Self.cachedSymbol(address) ?? Self.symbol(for: device)
        shownAddress = address
        let needsType = Self.cachedSymbol(address) == nil && Self.pnpSymbol(for: device) == nil

        // 연결 직후에는 배터리 값이 아직 없을 수 있다(AirPods 등). 팝업을 먼저 띄우면 숫자가 한 박자 늦게
        // 나타나므로, 최대 1.2초 동안 배터리를 먼저 찾아본 뒤 띄운다.
        // 찾으면 배터리 수치, 못 찾으면 '연결됨' (나중에 배터리가 오면 '연결됨'을 수치로 바꾼다 → 배터리 우선).
        resolveBattery(name: name, address: address, until: Date().addingTimeInterval(1.2)) { [weak self] battery in
            guard let self, self.shownAddress == address else { return }
            self.center.post(self.activity(name: name, symbol: symbol, connected: connected, battery: battery))
            guard battery?.primary == nil || needsType else { return }
            self.fetchBatteryLater(name: name, address: address, symbol: symbol, attempts: [0.6, 1.8, 3.6, 6.0])
        }
    }

    /// 배터리를 0.15초 간격으로 찾다가 기한이 지나면 nil.
    private func resolveBattery(name: String, address: String, until deadline: Date, completion: @escaping (Battery?) -> Void) {
        if let b = Self.accessoryBattery(name: name) ?? Self.hidBattery(name: name, address: address), b.primary != nil {
            completion(b)
        } else if Date() >= deadline {
            completion(nil)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.resolveBattery(name: name, address: address, until: deadline, completion: completion)
            }
        }
    }

    private func fetchBatteryLater(name: String, address: String, symbol: String, attempts: [TimeInterval]) {
        guard let delay = attempts.first else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            // ① macOS 배터리 위젯과 같은 액세서리 전원 목록 → ② Apple HID → ③ system_profiler
            var battery = Self.accessoryBattery(name: name) ?? Self.hidBattery(name: name, address: address)
            if battery == nil || Self.cachedSymbol(address) == nil {
                let profiled = Self.profilerBattery(address: address, name: name)
                if battery == nil { battery = profiled } else { battery?.symbol = profiled?.symbol }
            }
            DispatchQueue.main.async {
                guard let self, self.shownAddress == address else { return }
                if let s = battery?.symbol { Self.cacheSymbol(s, for: address) }
                if let battery, battery.primary != nil {
                    // 표시 중인 카드의 값만 스프링으로 채운다.
                    let updated = self.activity(name: name, symbol: symbol, connected: true, battery: battery)
                    self.center.update(.bluetooth) { a in
                        a.value = updated.value
                        a.valueTint = updated.valueTint
                        a.tint = updated.tint
                        a.detailValue = updated.detailValue
                        a.subtitle = updated.subtitle
                        a.wing = updated.wing
                        if let symbol = battery.symbol { a.symbol = symbol }
                    }
                } else {
                    self.fetchBatteryLater(name: name, address: address, symbol: symbol, attempts: Array(attempts.dropFirst()))
                }
            }
        }
    }

    private func activity(name: String, symbol: String, connected: Bool, battery: Battery?) -> NotchActivity {
        let level = battery?.primary.map { Double($0) / 100 }
        let value: ActivityValue
        // 컴팩트는 기기 이름 없이 아이콘 + 배터리(또는 연결됨/해제됨)만
        if !connected {
            value = .text(T("해제됨", "Disconnected"))
        } else if let level {
            switch settings.btBattery {
            case .percent: value = .percent(level)
            case .ring: value = .ring(level)
            case .both: value = .ringPercent(level)
            }
        } else {
            value = .text(T("연결됨", "Connected"))   // 배터리 정보가 없는 기기
        }
        // 배터리 수치는 초록색, 15% 미만이면 빨간색
        let tint: Color = (level ?? 1) < 0.15 ? .red : .green
        var subtitle = connected ? T("연결됨", "Connected") : T("연결 해제됨", "Disconnected")
        if let buds = battery?.budsSummary { subtitle = buds }

        return NotchActivity(
            kind: .bluetooth,
            presentation: settings.btStyle == .detail ? .detail : .compact,
            symbol: symbol,
            tint: connected ? tint : .gray,
            value: value,
            title: name,
            subtitle: subtitle,
            // 상세 카드도 설정의 배터리 표시 방식(백분율/원형/둘 다)을 따른다
            detailValue: level.map { level -> ActivityValue in
                switch settings.btBattery {
                case .percent: return .percent(level)
                case .ring: return .ring(level)
                case .both: return .ringPercent(level)
                }
            } ?? value,
            wing: {
                switch value {
                case .text(let t): return NetworkMonitor.wing(for: t)
                case .ringPercent: return 70
                default: return 56
                }
            }(),
            swapSides: false,   // 좌: 기기 아이콘, 우: 배터리 잔량
            valueTint: level == nil ? .white : tint
        )
    }

    static func isPhoneOrTablet(_ device: IOBluetoothDevice) -> Bool {
        if device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorPhone) { return true }
        let symbol = cachedSymbol(device.addressString ?? "") ?? nameSymbol((device.name ?? "").lowercased())
        return symbol == "iphone" || symbol == "ipad"
    }

    // MARK: - 아이콘

    static func symbol(for device: IOBluetoothDevice) -> String {
        if let s = pnpSymbol(for: device) { return s }
        if let s = nameSymbol((device.name ?? "").lowercased()) { return s }

        let major = device.deviceClassMajor
        let minor = device.deviceClassMinor
        switch major {
        case UInt32(kBluetoothDeviceClassMajorAudio):
            // 0x06 헤드폰, 0x01 웨어러블 헤드셋, 0x05 스피커
            if minor == 0x05 || minor == 0x0A { return "hifispeaker.fill" }
            return "headphones"
        case UInt32(kBluetoothDeviceClassMajorPeripheral):
            if minor & 0x10 != 0 { return "keyboard" }
            if minor & 0x20 != 0 { return "computermouse" }
            if minor & 0x0F == 0x01 || minor & 0x0F == 0x02 { return "gamecontroller.fill" }
            return "keyboard"
        case UInt32(kBluetoothDeviceClassMajorPhone):
            return "iphone"
        default:
            return "dot.radiowaves.left.and.right"
        }
    }

    // MARK: - 배터리

    /// macOS 배터리 위젯이 쓰는 액세서리 전원 목록 (비공개 IOPSCopyPowerSourcesByType, 액세서리 = 4).
    /// AirPods(좌·우·케이스), 블루투스 LE 마우스·키보드 등 배터리 서비스를 가진 기기가 이름으로 나온다.
    static func accessoryBattery(name: String) -> Battery? {
        typealias ByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
        guard let p = dlsym(dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW), "IOPSCopyPowerSourcesByType"),
              let info = unsafeBitCast(p, to: ByType.self)(4)?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var battery = Battery()
        var found = false
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let psName = d["Name"] as? String else { continue }
            let level = d["Current Capacity"] as? Int
            let part = d["Part Identifier"] as? String
            if psName == name {
                found = true
                if part == "Combined", let parts = d["Combined Parts"] as? [[String: Any]] {
                    for p in parts {
                        switch p["Part Identifier"] as? String {
                        case "Left": battery.left = p["Current Capacity"] as? Int
                        case "Right": battery.right = p["Current Capacity"] as? Int
                        default: break
                        }
                    }
                    if battery.left == nil && battery.right == nil { battery.main = level }
                } else if part == "Left" {
                    battery.left = level
                } else if part == "Right" {
                    battery.right = level
                } else {
                    battery.main = level
                }
            } else if part == "Case", psName.hasPrefix(name) {
                found = true
                battery.caseLevel = level
            }
        }
        return found && battery.primary != nil ? battery : nil
    }

    /// Apple Magic 액세서리: IOKit AppleDeviceManagementHIDEventService의 BatteryPercent.
    static func hidBattery(name: String, address: String) -> Battery? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let wanted = normalize(address)
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            func prop(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let percent = prop("BatteryPercent") as? Int else { continue }
            let product = prop("Product") as? String ?? ""
            let devAddress = normalize(prop("DeviceAddress") as? String ?? "")
            if (!wanted.isEmpty && devAddress == wanted) || (!product.isEmpty && product == name) {
                return Battery(main: percent)
            }
        }
        return nil
    }

    /// AirPods·서드파티: system_profiler의 블루투스 정보 (느리므로 백그라운드에서만 호출).
    static func profilerBattery(address: String, name: String) -> Battery? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = json["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        let wanted = normalize(address)
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (deviceName, raw) in entry {
                    guard let info = raw as? [String: Any] else { continue }
                    let devAddress = normalize(info["device_address"] as? String ?? "")
                    guard devAddress == wanted || deviceName == name else { continue }
                    func level(_ key: String) -> Int? {
                        (info[key] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
                    }
                    let b = Battery(main: level("device_batteryLevelMain"),
                                    left: level("device_batteryLevelLeft"),
                                    right: level("device_batteryLevelRight"),
                                    caseLevel: level("device_batteryLevelCase"),
                                    symbol: appleSymbol(vendor: info["device_vendorID"] as? String,
                                                        product: info["device_productID"] as? String)
                                        ?? minorTypeSymbol(info["device_minorType"] as? String))
                    return b.primary == nil && b.symbol == nil ? nil : b
                }
            }
        }
        return nil
    }

    /// Apple 제품 ID → SF Symbol (이름을 바꾼 AirPods도 모양 아이콘으로).
    static func appleSymbol(vendor: String?, product: String?) -> String? {
        guard vendor?.lowercased() == "0x004c", let product = product?.lowercased() else { return nil }
        switch product {
        case "0x200e", "0x2014", "0x2024", "0x2027": return "airpodspro"        // AirPods Pro 1·2
        case "0x200a", "0x201f": return "airpodsmax"                             // AirPods Max
        case "0x2002", "0x200f": return "airpods"                                // AirPods 1·2
        case "0x2013": return "airpods.gen3"                                     // AirPods 3
        case "0x2019", "0x201b", "0x2026": return "airpods.gen4"                 // AirPods 4
        case "0x2003", "0x200b", "0x200c", "0x2010", "0x2011", "0x2012", "0x2016", "0x2017", "0x201d":
            return "beats.headphones"                                            // Beats
        case "0x0269": return "magicmouse"                                       // Magic Mouse 2
        case "0x0265": return "rectangle.and.hand.point.up.left"                 // Magic Trackpad 2
        case "0x0267", "0x026c": return "keyboard"                               // Magic Keyboard
        default: return nil
        }
    }

    /// 기기가 SDP로 알려 준 PnP 정보(제조사·제품 ID)로 아이콘을 고른다. 연결 직후 바로 읽을 수 있다.
    static func pnpSymbol(for device: IOBluetoothDevice) -> String? {
        guard let records = device.services as? [IOBluetoothSDPServiceRecord] else { return nil }
        let pnp = IOBluetoothSDPUUID(uuid16: 0x1200)
        for r in records where r.matchesUUIDArray([pnp as Any]) {
            guard let vendor = r.getAttributeDataElement(0x0201)?.getNumberValue()?.intValue,
                  let product = r.getAttributeDataElement(0x0202)?.getNumberValue()?.intValue else { continue }
            return appleSymbol(vendor: String(format: "0x%04x", vendor), product: String(format: "0x%04x", product))
        }
        return nil
    }

    /// system_profiler의 기기 종류(minorType)로 아이콘을 고른다 (Apple 외 기기).
    static func minorTypeSymbol(_ type: String?) -> String? {
        switch type?.lowercased() ?? "" {
        case "mouse": return "computermouse"
        case "keyboard": return "keyboard"
        case "gamepad", "joystick": return "gamecontroller.fill"
        case "headphones", "headset", "headphone": return "headphones"
        case "speaker", "loudspeaker": return "hifispeaker.fill"
        case "trackpad": return "rectangle.and.hand.point.up.left"
        default: return nil
        }
    }

    // 한 번 알아낸 기기 아이콘은 주소별로 기억해 다음 연결부터 바로 쓴다.
    private static let symbolCacheKey = "btSymbolCache"

    static func cachedSymbol(_ address: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: symbolCacheKey) as? [String: String])?[normalize(address)]
    }

    static func cacheSymbol(_ symbol: String, for address: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: symbolCacheKey) as? [String: String]) ?? [:]
        dict[normalize(address)] = symbol
        UserDefaults.standard.set(dict, forKey: symbolCacheKey)
    }

    private static func normalize(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: "-", with: ":")
    }
}
