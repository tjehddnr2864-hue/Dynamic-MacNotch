import AppKit
import SwiftUI
import CoreAudio
import AudioToolbox

/// 시스템 HUD 대체 (가이드라인 5.9): 음량·화면 밝기·키보드 밝기 키를 가로채 앱이 직접 값을 바꾸고
/// 노치 HUD(좌: 아이콘, 우: 숫자/가로 바/원형)를 띄운다. 가로챈 키는 시스템에 전달하지 않으므로 시스템 HUD가 뜨지 않는다.
/// 앱이 종료되면 탭도 사라져 시스템 HUD가 그대로 돌아온다.
final class HUDMonitor: ObservableObject {
    @Published private(set) var tapActive = false

    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private var tap: CFMachPort?
    private var retryTimer: Timer?
    private var lastOwnChange = Date.distantPast
    private var lastDisplay: Float?
    private var lastKeyboard: Float?

    // NX_KEYTYPE_*
    private enum Key: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
        case illuminationUp = 21, illuminationDown = 22, illuminationToggle = 23
    }

    init(center: ActivityCenter) {
        self.center = center
    }

    func start() {
        installTap()
        if tap == nil {
            // 손쉬운 사용 권한이 허용될 때까지 3초마다 다시 시도한다.
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                self.installTap()
                if self.tap != nil { timer.invalidate() }
            }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            retryTimer = t
        }
        observeAudio()
        lastDisplay = Brightness.display()
        lastKeyboard = Brightness.keyboard()
        // 밝기는 주기적으로 읽지 않고, 값이 바뀔 때 시스템이 보내는 알림으로만 처리한다 (idle CPU 0).
        Brightness.observeDisplay { [weak self] value in self?.externalDisplayChange(value) }
        Brightness.observeKeyboard { [weak self] value in self?.externalKeyboardChange(value) }
    }

    // MARK: - 이벤트 탭

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HUDMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else { return }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapActive = true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let code = (ns.data1 & 0xFFFF0000) >> 16
        let flags = ns.data1 & 0x0000FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0xA
        guard let key = Key(rawValue: code) else { return Unmanaged.passUnretained(event) }

        let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
        let handled: Bool
        switch key {
        case .soundUp, .soundDown, .mute:
            handled = settings.hudVolume && (!isDown || changeVolume(key, fine: fine))
        case .brightnessUp, .brightnessDown:
            handled = settings.hudDisplay && Brightness.displayAvailable
                && (!isDown || changeDisplay(up: key == .brightnessUp, fine: fine))
        case .illuminationUp, .illuminationDown, .illuminationToggle:
            handled = settings.hudKeyboard && Brightness.keyboardAvailable
                && (!isDown || changeKeyboard(key, fine: fine))
        }
        // 처리한 키는 삼켜서 시스템 HUD가 뜨지 않게 한다.
        return handled ? nil : Unmanaged.passUnretained(event)
    }

    private static func step(_ value: Float, up: Bool, fine: Bool) -> Float {
        let unit: Float = fine ? 1 / 64 : 1 / 16
        let next = ((value / unit).rounded() + (up ? 1 : -1)) * unit
        return min(1, max(0, next))
    }

    // MARK: - 음량

    private func changeVolume(_ key: Key, fine: Bool) -> Bool {
        let device = AudioOutput.defaultDevice()
        guard let volume = AudioOutput.volume(device) else { return false }   // 조절 불가 기기는 시스템에 넘긴다
        lastOwnChange = Date()
        switch key {
        case .mute:
            AudioOutput.setMuted(device, !AudioOutput.isMuted(device))
        default:
            let up = key == .soundUp
            if AudioOutput.isMuted(device) { AudioOutput.setMuted(device, false) }
            AudioOutput.setVolume(device, Self.step(volume, up: up, fine: fine))
        }
        showVolume()
        return true
    }

    private func showVolume() {
        let device = AudioOutput.defaultDevice()
        guard let volume = AudioOutput.volume(device) else { return }
        let muted = AudioOutput.isMuted(device)
        let level = muted ? 0 : volume
        var symbol: String
        switch level {
        case ..<0.001: symbol = "speaker.slash.fill"
        case ..<0.34: symbol = "speaker.wave.1.fill"
        case ..<0.67: symbol = "speaker.wave.2.fill"
        default: symbol = "speaker.wave.3.fill"
        }
        if settings.hudOutputIcon, !muted, let deviceSymbol = AudioOutput.currentSymbol() {
            symbol = deviceSymbol
        }
        post(symbol: symbol, value: Double(level), tint: .white)
    }

    /// 제어 센터 등 키 없이 바뀐 음량도 표시한다. 기본 출력 기기 음량 구독은 OutputRoute 한 곳에서만 한다.
    private func observeAudio() {
        OutputRoute.shared.onExternalVolumeChange = { [weak self] in
            // 방금 키로 바꾼 값은 이미 표시됨, 음악 팝업 음량 바에서 바꾼 값은 HUD를 띄우지 않음
            guard let self, self.settings.hudVolume,
                  Date().timeIntervalSince(self.lastOwnChange) > 0.4,
                  Date().timeIntervalSince(AudioOutput.lastUIChange) > 0.6 else { return }
            self.showVolume()
        }
    }

    // MARK: - 화면 밝기

    private func changeDisplay(up: Bool, fine: Bool) -> Bool {
        guard let value = Brightness.display() else { return false }
        let next = Self.step(value, up: up, fine: fine)
        Brightness.setDisplay(next)
        lastDisplay = next
        lastOwnChange = Date()
        post(symbol: next < 0.5 ? "sun.min.fill" : "sun.max.fill", value: Double(next), tint: .yellow)
        return true
    }

    // MARK: - 키보드 밝기

    private func changeKeyboard(_ key: Key, fine: Bool) -> Bool {
        guard let value = Brightness.keyboard() else { return false }
        let next: Float
        switch key {
        case .illuminationToggle: next = value > 0 ? 0 : 0.5
        default: next = Self.step(value, up: key == .illuminationUp, fine: fine)
        }
        Brightness.setKeyboard(next)
        lastKeyboard = next
        lastOwnChange = Date()
        showKeyboard(next)
        return true
    }

    private func showKeyboard(_ value: Float) {
        post(symbol: value > 0 ? "light.max" : "light.min", value: Double(value), tint: .white)
    }

    // MARK: - 키 없이 바뀐 밝기 (제어 센터 등)

    // 키 입력이 아닌 변화는 '제어 센터·시스템 설정에서 사용자가 직접 바꾼 경우'에만 표시한다.
    // 주변광에 따른 자동 밝기·키보드 백라이트(유휴 시 어두워짐 포함) 변화는 표시하지 않는다.
    private func externalKeyboardChange(_ kb: Float) {
        defer { lastKeyboard = kb }
        guard Date().timeIntervalSince(lastOwnChange) > 0.6, let last = lastKeyboard, abs(kb - last) >= 0.01,
              settings.hudKeyboard, settings.hudKeyboardExternal, manualAdjustment() else { return }
        showKeyboard(kb)
    }

    private func externalDisplayChange(_ d: Float) {
        defer { lastDisplay = d }
        guard Date().timeIntervalSince(lastOwnChange) > 0.6, let last = lastDisplay, abs(d - last) >= 0.01,
              settings.hudDisplay, settings.hudDisplayExternal, manualAdjustment() else { return }
        post(symbol: d < 0.5 ? "sun.min.fill" : "sun.max.fill", value: Double(d), tint: .yellow)
    }

    /// 자동 밝기는 짧은 간격으로 알림을 연달아 보내므로, 창 목록 조회 결과를 0.5초 동안 재사용한다.
    private var manualCache: (time: Date, value: Bool) = (.distantPast, false)

    private func manualAdjustment() -> Bool {
        if Date().timeIntervalSince(manualCache.time) < 0.5 { return manualCache.value }
        let v = Self.userIsAdjustingManually()
        manualCache = (Date(), v)
        return v
    }

    /// 사용자가 밝기를 직접 조절하는 중인지: 제어 센터 패널이 열려 있거나 시스템 설정이 앞에 있을 때.
    static func userIsAdjustingManually() -> Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" { return true }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        // 창 소유자 이름은 언어별로 바뀌므로(예: '제어 센터') 프로세스의 번들 ID로 확인한다.
        let ccPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").map(\.processIdentifier))
        guard !ccPIDs.isEmpty else { return false }
        return list.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, ccPIDs.contains(pid),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            // 메뉴바 아이콘(작은 창)이 아닌, 펼쳐진 패널
            return (b["Height"] ?? 0) > 80 && (b["Width"] ?? 0) > 150
        }
    }

    // MARK: - 표시

    private func post(symbol: String, value: Double, tint: Color) {
        let v: ActivityValue
        switch settings.hudStyle {
        case .number: v = .bigNumber(value)
        case .bar: v = .bar(value)
        case .ring: v = .ring(value)
        }
        center.post(NotchActivity(
            kind: .hud, priority: ActivityPriority.hud,
            duration: settings.hudDuration,
            symbol: symbol, tint: tint, value: v,
            wing: settings.hudStyle == .bar ? 66 : 54
        ))
    }
}

// MARK: - CoreAudio

enum AudioOutput {
    /// 앱 화면(음악 팝업 음량 줄)에서 음량을 바꾼 시각. 이때는 음량 HUD를 띄우지 않는다.
    static var lastUIChange = Date.distantPast

    static func defaultDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func volume(_ device: AudioDeviceID) -> Float? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setVolume(_ device: AudioDeviceID, _ value: Float) {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var v = Float32(value)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return value != 0
    }

    static func setMuted(_ device: AudioDeviceID, _ muted: Bool) {
        var addr = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &addr) else { return }
        var v = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    static func name(_ device: AudioDeviceID) -> String? {
        var addr = address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    /// 기본 출력 기기 아이콘 (OutputRoute가 기기가 바뀔 때만 계산해 둔 값). 맥북 스피커면 nil(음량 단계 아이콘 사용).
    static func currentSymbol() -> String? {
        let s = OutputRoute.shared.symbol
        return s == "macbook" ? nil : s
    }
}

// MARK: - 밝기 (비공개 프레임워크, 동적 로드)

enum Brightness {
    private typealias GetDisplay = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetDisplay = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetKeyboard = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetKeyboard = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getDisplay: GetDisplay? = displayServices.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetDisplay.self) }
    private static let setDisplayFn: SetDisplay? = displayServices.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetDisplay.self) }

    private static let keyboardClient: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    private static let keyboardID: UInt64 = {
        guard let client = keyboardClient else { return 1 }
        let sel = NSSelectorFromString("copyKeyboardBackLightIDs")
        guard client.responds(to: sel),
              let ids = client.perform(sel)?.takeUnretainedValue() as? [NSNumber],
              let first = ids.first else { return 1 }
        return first.uint64Value
    }()

    static var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }

    // MARK: 변경 알림 (폴링 대신)

    private typealias RegisterDisplay = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    private typealias RegisterKeyboard = @convention(c) (AnyObject, Selector, NSArray, UInt64,
                                                         @escaping @convention(block) (AnyObject?, AnyObject?) -> Void) -> Void
    private static var displayHandler: ((Float) -> Void)?

    /// 화면 밝기가 바뀌면 DisplayServices가 'DisplayServicesBrightness' 알림(value)을 보낸다.
    static func observeDisplay(_ handler: @escaping (Float) -> Void) {
        guard let id = builtInDisplay, let p = displayServices.flatMap({ dlsym($0, "DisplayServicesRegisterForBrightnessChangeNotifications") }) else { return }
        displayHandler = handler
        _ = unsafeBitCast(p, to: RegisterDisplay.self)(id, nil) { _, _, _, _, info in
            let raw = (info as NSDictionary?)?["value"]
            let value = (raw as? NSNumber)?.floatValue ?? (raw as? String).flatMap(Float.init)
            guard let value else { return }
            DispatchQueue.main.async { Brightness.displayHandler?(value) }
        }
    }

    /// 키보드 백라이트가 바뀌면 CoreBrightness가 'KeyboardBacklightBrightness' 키로 알린다.
    static func observeKeyboard(_ handler: @escaping (Float) -> Void) {
        guard let client = keyboardClient else { return }
        let sel = NSSelectorFromString("registerNotificationForKeys:keyboardID:block:")
        guard client.responds(to: sel) else { return }
        let fn = unsafeBitCast(client.method(for: sel), to: RegisterKeyboard.self)
        fn(client, sel, ["KeyboardBacklightBrightness"] as NSArray, keyboardID) { key, value in
            guard (key as? String) == "KeyboardBacklightBrightness", let v = (value as? NSNumber)?.floatValue else { return }
            DispatchQueue.main.async { handler(v) }
        }
    }

    static var displayAvailable: Bool { getDisplay != nil && setDisplayFn != nil && builtInDisplay != nil }

    static func display() -> Float? {
        guard let getDisplay, let id = builtInDisplay else { return nil }
        var value: Float = 0
        return getDisplay(id, &value) == 0 ? value : nil
    }

    static func setDisplay(_ value: Float) {
        guard let setDisplayFn, let id = builtInDisplay else { return }
        _ = setDisplayFn(id, value)
    }

    static var keyboardAvailable: Bool {
        guard let client = keyboardClient else { return false }
        return client.responds(to: NSSelectorFromString("brightnessForKeyboard:"))
            && client.responds(to: NSSelectorFromString("setBrightness:forKeyboard:"))
    }

    static func keyboard() -> Float? {
        guard keyboardAvailable, let client = keyboardClient else { return nil }
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        let fn = unsafeBitCast(client.method(for: sel), to: GetKeyboard.self)
        return fn(client, sel, keyboardID)
    }

    static func setKeyboard(_ value: Float) {
        guard keyboardAvailable, let client = keyboardClient else { return }
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        let fn = unsafeBitCast(client.method(for: sel), to: SetKeyboard.self)
        _ = fn(client, sel, value, keyboardID)
    }
}
