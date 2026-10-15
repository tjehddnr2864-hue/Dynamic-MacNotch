import AppKit
import SwiftUI
import CoreAudio
import AudioToolbox
import IOBluetooth

// MARK: - 출력 기기 목록·전환

extension AudioOutput {
    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// 기본 출력으로 고를 수 있는 기기 (숨김·입력 전용 제외)
    static func outputDevices() -> [AudioDeviceID] {
        var addr = globalAddress(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return false }
            var canDefault = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                                        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var flag = UInt32(1)
            var flagSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectHasProperty(id, &canDefault) {
                AudioObjectGetPropertyData(id, &canDefault, 0, nil, &flagSize, &flag)
            }
            return flag != 0
        }
    }

    static func setDefault(_ device: AudioDeviceID) {
        var id = device
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let system = AudioObjectID(kAudioObjectSystemObject)
        // 시스템 효과음도 같은 기기로 나오고 있었다면 함께 옮긴다 (사운드 설정의 기본 동작과 같음)
        var sysAddr = globalAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var sysID = AudioDeviceID(0)
        var sysSize = size
        AudioObjectGetPropertyData(system, &sysAddr, 0, nil, &sysSize, &sysID)
        let followSystem = sysID == defaultDevice()
        var addr = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(system, &addr, 0, nil, size, &id)
        if followSystem {
            AudioObjectSetPropertyData(system, &sysAddr, 0, nil, size, &id)
        }
    }

    /// 메뉴에 보일 이름 (이름이 비어 있는 HDMI 기기 등은 종류로 대신)
    static func displayName(_ device: AudioDeviceID) -> String {
        if let n = name(device)?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        switch transport(device) {
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return T("외부 디스플레이", "External Display")
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        default: return T("알 수 없는 기기", "Unknown Device")
        }
    }

    static func uid(_ device: AudioDeviceID) -> String? {
        var addr = globalAddress(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    static func transport(_ device: AudioDeviceID) -> UInt32 {
        var addr = globalAddress(kAudioDevicePropertyTransportType)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport)
        return transport
    }

    /// 블루투스 오디오 기기의 MAC 주소 (UID가 "AA-BB-CC-DD-EE-FF:output" 꼴)
    static func bluetoothAddress(_ device: AudioDeviceID) -> String? {
        guard let uid = uid(device), uid.count >= 17 else { return nil }
        let addr = String(uid.prefix(17))
        return addr.filter { $0 == "-" || $0 == ":" }.count == 5 ? addr : nil
    }

    /// 블루투스 기기 아이콘: 기억해 둔 아이콘 → 제품 ID(PnP) → 이름 순으로 찾는다.
    /// 이름을 바꾼 AirPods도 제품 ID로 알아본다.
    static func bluetoothSymbol(_ device: AudioDeviceID) -> String? {
        if let addr = bluetoothAddress(device) {
            if let s = BluetoothMonitor.cachedSymbol(addr) { return s }
            if let d = IOBluetoothDevice(addressString: addr) {
                let s = BluetoothMonitor.symbol(for: d)
                if s != "dot.radiowaves.left.and.right" { return s }
            }
        }
        let n = name(device) ?? ""
        if let d = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: { $0.name == n }) {
            if let s = BluetoothMonitor.cachedSymbol(d.addressString ?? "") { return s }
            return BluetoothMonitor.symbol(for: d)
        }
        return nil
    }

    /// 출력 기기 종류별 아이콘 (항상 값이 있음): 맥북 스피커·헤드폰·AirPods·디스플레이·AirPlay 등
    static func deviceSymbol(_ device: AudioDeviceID) -> String {
        let lowered = (name(device) ?? "").lowercased()
        let isHeadphone = lowered.contains("headphone") || lowered.contains("헤드폰") || lowered.contains("headset") || lowered.contains("헤드셋")
        switch transport(device) {
        case kAudioDeviceTransportTypeBuiltIn:
            return isHeadphone ? "headphones" : "macbook"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if let s = bluetoothSymbol(device), s.hasPrefix("airpods") || s.hasPrefix("beats") || s == "headphones" || s == "hifispeaker.fill" || s == "earbuds" {
                return s
            }
            return BluetoothMonitor.nameSymbol(lowered) ?? "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return lowered.contains("tv") ? "tv" : "display"
        case kAudioDeviceTransportTypeAirPlay:
            if lowered.contains("homepod mini") { return "homepodmini.fill" }
            if lowered.contains("homepod") { return "homepod.fill" }
            if lowered.contains("apple tv") { return "appletv.fill" }
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            if lowered.contains("display") || lowered.contains("디스플레이") { return "display" }
            return isHeadphone ? "headphones" : "hifispeaker.fill"
        default:
            return isHeadphone ? "headphones" : "speaker.wave.2.fill"
        }
    }
}

// MARK: - 현재 출력 기기 (이벤트 구독, 폴링 없음)

final class OutputRoute: ObservableObject {
    static let shared = OutputRoute()

    @Published private(set) var symbol = "macbook"
    @Published private(set) var name = ""
    /// 현재 출력 기기 음량 (조절할 수 없는 기기면 nil)과 음소거
    @Published private(set) var volume: Float?
    @Published private(set) var muted = false
    private var connectWork: DispatchWorkItem?
    private var volumeDevice = AudioDeviceID(0)
    /// 음량·음소거가 바뀔 때 (HUDMonitor가 음량 HUD를 띄우는 데 사용)
    var onExternalVolumeChange: (() -> Void)?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private static let volumeSelectors = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute]

    private init() {
        refresh()
        // 기본 출력 기기가 바뀌거나, 기기가 연결·해제되면 갱신
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
                self?.refresh()
            }
        }
    }

    func refresh() {
        let device = AudioOutput.defaultDevice()
        let s = AudioOutput.deviceSymbol(device)
        let n = AudioOutput.displayName(device)
        if s != symbol { symbol = s }
        if n != name { name = n }
        listenVolume(device)
    }

    /// 기본 출력 기기의 음량·음소거 변화를 구독한다 (기기가 바뀌면 이전 기기에서 떼어 낸다).
    private func listenVolume(_ device: AudioDeviceID) {
        guard device != volumeDevice else { return }
        if let old = volumeListener, volumeDevice != 0 {
            for selector in Self.volumeSelectors {
                var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                      mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(volumeDevice, &addr, .main, old)
            }
        }
        volumeDevice = device
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.readVolume()
            self?.onExternalVolumeChange?()
        }
        volumeListener = listener
        for selector in Self.volumeSelectors {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(device, &addr, .main, listener)
        }
        readVolume()
    }

    private func readVolume() {
        let v = AudioOutput.volume(volumeDevice)
        let m = AudioOutput.isMuted(volumeDevice)
        if v != volume { volume = v }
        if m != muted { muted = m }
    }

    /// 음악 팝업 음량 줄에서 음량을 바꾼다 (음량 HUD는 띄우지 않음). 0보다 크게 올리면 음소거를 푼다.
    func setVolume(_ value: Float) {
        let v = min(max(value, 0), 1)
        AudioOutput.lastUIChange = Date()
        AudioOutput.setVolume(volumeDevice, v)
        if muted, v > 0 { AudioOutput.setMuted(volumeDevice, false) }
        volume = v
    }

    func toggleMute() {
        AudioOutput.lastUIChange = Date()
        AudioOutput.setMuted(volumeDevice, !muted)
        readVolume()
    }

    func select(_ device: AudioDeviceID) {
        connectWork?.cancel()
        AudioOutput.setDefault(device)
    }

    /// 페어링만 된(연결 끊긴) 블루투스 오디오 기기 — 고르면 연결한 뒤 출력으로 지정한다.
    static func connectableBluetooth() -> [IOBluetoothDevice] {
        ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).filter {
            !$0.isConnected() && $0.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio)
                && !BluetoothMonitor.isPhoneOrTablet($0)
        }
    }

    func connectAndSelect(_ device: IOBluetoothDevice) {
        connectWork?.cancel()
        guard let address = device.addressString?.lowercased().replacingOccurrences(of: ":", with: "-") else { return }
        // 비동기 연결 (target을 주면 메인 스레드를 막지 않는다)
        device.openConnection(BluetoothConnectTarget.shared)
        // 오디오 기기로 나타날 때까지 잠깐(최대 10초) 기다렸다가 출력으로 지정
        var tries = 0
        func check() {
            tries += 1
            if let match = AudioOutput.outputDevices().first(where: {
                AudioOutput.bluetoothAddress($0)?.lowercased().replacingOccurrences(of: ":", with: "-") == address
            }) {
                AudioOutput.setDefault(match)
                return
            }
            guard tries < 20 else { return }
            let work = DispatchWorkItem { check() }
            connectWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        check()
    }
}

private final class BluetoothConnectTarget: NSObject {
    static let shared = BluetoothConnectTarget()
    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {}
}

// MARK: - 출력 기기 선택 버튼 (아이콘 + 메뉴)

struct OutputPickerButton: View {
    @ObservedObject private var route = OutputRoute.shared
    var iconSize: CGFloat = 17
    var frame: CGFloat = 30
    var opacity: Double = 0.85
    /// 길게 누르면 (음악 팝업: 음량 줄 펼치기/접기)
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        ZStack {
            OutputMenuAnchor(onLongPress: onLongPress)
            Image(systemName: route.symbol)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white.opacity(opacity))
                .contentTransition(.symbolEffect(.replace))
                .allowsHitTesting(false)
        }
        .frame(width: frame, height: frame)
        .help(onLongPress == nil ? (route.name.isEmpty ? T("출력 기기 선택", "Choose Output") : T("출력: \(route.name)", "Output: \(route.name)"))
                                 : T("클릭: 출력 기기 선택 · 길게 누르기: 음량", "Click: choose output · Long press: volume"))
    }
}

private struct OutputMenuAnchor: NSViewRepresentable {
    var onLongPress: (() -> Void)?

    func makeNSView(context: Context) -> OutputMenuView {
        let v = OutputMenuView()
        v.onLongPress = onLongPress
        return v
    }

    func updateNSView(_ nsView: OutputMenuView, context: Context) { nsView.onLongPress = onLongPress }
}

final class OutputMenuView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 화면에 떠 있는 버튼 (개발용 명령에서 메뉴를 열 때 사용)
    static weak var visible: OutputMenuView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.visible = self }
    }

    var onLongPress: (() -> Void)?
    static let longPressDelay: TimeInterval = 0.4

    /// 짧게 누르면 출력 기기 메뉴, 길게(0.4초) 누르면 onLongPress.
    override func mouseDown(with event: NSEvent) {
        guard let onLongPress, let window else { showMenu(); return }
        let released = window.nextEvent(matching: [.leftMouseUp], until: Date().addingTimeInterval(Self.longPressDelay),
                                        inMode: .eventTracking, dequeue: true)
        if released != nil {
            showMenu()
        } else {
            Haptics.perform()
            onLongPress()
        }
    }

    func showMenu(autoClose: TimeInterval? = nil) {
        let menu = buildMenu()
        if let autoClose {
            let timer = Timer(timeInterval: autoClose, repeats: false) { [weak menu] _ in menu?.cancelTracking() }
            RunLoop.main.add(timer, forMode: .common)
        }
        let y = isFlipped ? bounds.maxY + 6 : bounds.minY - 6
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: y), in: self)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: T("출력 기기", "Output")))
        let current = AudioOutput.defaultDevice()
        for device in AudioOutput.outputDevices() {
            let item = NSMenuItem(title: AudioOutput.displayName(device), action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(device)
            item.image = Self.icon(AudioOutput.deviceSymbol(device))
            item.state = device == current ? .on : .off
            menu.addItem(item)
        }
        let connectable = OutputRoute.connectableBluetooth()
        if !connectable.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: T("연결 가능한 기기", "Available Devices")))
            for d in connectable {
                let item = NSMenuItem(title: d.name ?? T("블루투스 기기", "Bluetooth Device"), action: #selector(connect(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = d
                let symbol = BluetoothMonitor.cachedSymbol(d.addressString ?? "") ?? BluetoothMonitor.symbol(for: d)
                item.image = Self.icon(symbol)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: T("사운드 설정…", "Sound Settings…"), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    private static func icon(_ symbol: String) -> NSImage? {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
        return img?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }

    @objc private func pick(_ item: NSMenuItem) {
        OutputRoute.shared.select(AudioDeviceID(item.tag))
    }

    @objc private func connect(_ item: NSMenuItem) {
        guard let d = item.representedObject as? IOBluetoothDevice else { return }
        OutputRoute.shared.connectAndSelect(d)
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }
}

/// 현재 출력 기기 아이콘만 (잠금 화면용)
struct OutputIcon: View {
    @ObservedObject private var route = OutputRoute.shared

    var body: some View {
        Image(systemName: route.symbol)
            .contentTransition(.symbolEffect(.replace))
    }
}
