import AppKit
import AVFoundation
import CoreBluetooth
import CoreLocation
import EventKit
import Intents
import ServiceManagement
import UserNotifications

enum PermissionTier: Int, CaseIterable {
    case required, recommended, optional
    var label: String {
        switch self {
        case .required: return T("필수", "Required")
        case .recommended: return T("권장", "Recommended")
        case .optional: return T("선택", "Optional")
        }
    }
}

enum PermissionStatus: Equatable {
    case granted, notDetermined, denied, needsAppRunning, unknown

    var label: String {
        switch self {
        case .granted: return T("허용됨", "Allowed")
        case .notDetermined: return T("필요", "Needed")
        case .denied: return T("거부됨", "Denied")
        case .needsAppRunning: return T("앱 실행 필요", "App must be running")
        case .unknown: return T("확인 안 됨", "Unknown")
        }
    }
}

/// 가이드라인 6장의 권한 목록.
enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility, inputMonitoring, screenRecording, camera, calendar, bluetooth
    case location, automation, focus, fullDisk, files, notifications, loginItem

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return T("손쉬운 사용", "Accessibility")
        case .inputMonitoring: return T("입력 모니터링", "Input Monitoring")
        case .screenRecording: return T("화면 및 시스템 오디오 녹음", "Screen & System Audio Recording")
        case .camera: return T("카메라", "Camera")
        case .calendar: return T("캘린더(전체 접근)", "Calendars (Full Access)")
        case .bluetooth: return T("블루투스", "Bluetooth")
        case .location: return T("위치 서비스", "Location Services")
        case .automation: return T("자동화(Music, Spotify)", "Automation (Music, Spotify)")
        case .focus: return T("집중 모드 상태", "Focus Status")
        case .fullDisk: return T("전체 디스크 접근", "Full Disk Access")
        case .files: return T("파일 및 폴더(다운로드, 데스크탑)", "Files & Folders (Downloads, Desktop)")
        case .notifications: return T("알림", "Notifications")
        case .loginItem: return T("로그인 시 실행", "Open at Login")
        }
    }

    var purpose: String {
        switch self {
        case .accessibility: return T("HUD 대체, 화면 녹화 정지, 드래그 감지, 전화 받기·끊기", "HUD replacement, stop recording, drag detection, answer/end calls")
        case .inputMonitoring: return T("밝기·음량 키 가로채기", "Intercept brightness and volume keys")
        case .screenRecording: return T("화면 녹화 감지", "Detect screen recording")
        case .camera: return T("노치 카메라(거울)", "Notch camera (mirror)")
        case .calendar: return T("오늘 일정 표시", "Show today's events")
        case .bluetooth: return T("액세서리 연결·배터리 표시", "Accessory connection and battery")
        case .location: return T("Wi-Fi 이름(SSID) 표시", "Show Wi-Fi name (SSID)")
        case .automation: return T("미디어 제어, 가사", "Media control, lyrics")
        case .focus: return T("집중 모드 켜짐/꺼짐 표시", "Show Focus on/off")
        case .fullDisk: return T("집중 모드 이름·아이콘 표시", "Show Focus name and icon")
        case .files: return T("다운로드 감지, 스크린샷 저장", "Detect downloads, save screenshots")
        case .notifications: return T("노치를 숨겼을 때 대체 알림", "Fallback alerts when the notch is hidden")
        case .loginItem: return T("로그인하면 자동 실행", "Launch automatically at login")
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        case .screenRecording: return "record.circle"
        case .camera: return "camera"
        case .calendar: return "calendar"
        case .bluetooth: return "wave.3.right"
        case .location: return "location"
        case .automation: return "gearshape.2"
        case .focus: return "moon"
        case .fullDisk: return "internaldrive"
        case .files: return "folder"
        case .notifications: return "bell.badge"
        case .loginItem: return "power"
        }
    }

    var tier: PermissionTier {
        switch self {
        case .accessibility, .inputMonitoring: return .required
        case .screenRecording, .camera, .calendar, .bluetooth, .automation, .files, .loginItem: return .recommended
        case .location, .focus, .fullDisk, .notifications: return .optional
        }
    }

    /// 허용 후 앱을 다시 시작해야 반영되는 권한.
    var needsRelaunch: Bool { self == .inputMonitoring || self == .screenRecording }

    var settingsURL: URL? {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .camera: anchor = "Privacy_Camera"
        case .calendar: anchor = "Privacy_Calendars"
        case .bluetooth: anchor = "Privacy_Bluetooth"
        case .location: anchor = "Privacy_LocationServices"
        case .automation: anchor = "Privacy_Automation"
        case .focus: anchor = "Privacy_Focus"
        case .fullDisk: anchor = "Privacy_AllFiles"
        case .files: anchor = "Privacy_FilesAndFolders"
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        case .loginItem:
            return URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

/// 권한 상태 조회와 요청.
final class PermissionsManager: NSObject, ObservableObject, CLLocationManagerDelegate, CBCentralManagerDelegate {
    static let shared = PermissionsManager()

    @Published private(set) var statuses: [PermissionKind: PermissionStatus] = [:]

    private let eventStore = EKEventStore()
    private let locationManager = CLLocationManager()
    private var bluetoothManager: CBCentralManager?
    private var refreshTimer: Timer?
    private let filesRequestedKey = "filesPermissionRequested"
    private static let automationTargets = ["com.apple.Music", "com.spotify.client"]

    override init() {
        super.init()
        locationManager.delegate = self
        refresh()
    }

    var grantedCount: Int { statuses.values.filter { $0 == .granted }.count }

    func status(_ kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .unknown }

    // MARK: - 주기적 갱신 (창이 열려 있는 동안 1초마다)

    func startAutoRefresh() {
        refresh()
        refreshTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        var s: [PermissionKind: PermissionStatus] = [:]
        s[.accessibility] = AXIsProcessTrusted() ? .granted : .notDetermined
        s[.inputMonitoring] = CGPreflightListenEventAccess() ? .granted : .notDetermined
        s[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        s[.camera] = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        s[.calendar] = Self.map(EKEventStore.authorizationStatus(for: .event))
        s[.bluetooth] = Self.map(CBManager.authorization)
        s[.location] = Self.map(locationManager.authorizationStatus)
        s[.focus] = Self.map(INFocusStatusCenter.default.authorizationStatus)
        s[.fullDisk] = Self.hasFullDiskAccess() ? .granted : .notDetermined
        s[.files] = filesStatus()
        s[.loginItem] = Self.map(SMAppService.mainApp.status)
        s[.automation] = statuses[.automation] ?? .unknown
        s[.notifications] = statuses[.notifications] ?? .unknown
        statuses = s

        refreshAutomation()
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: PermissionStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional: status = .granted
            case .denied: status = .denied
            default: status = .notDetermined
            }
            DispatchQueue.main.async { self.statuses[.notifications] = status }
        }
    }

    // MARK: - 요청

    func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) { openSettings(kind) }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openSettings(kind) }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSettings(kind) }
        case .camera:
            if status(kind) == .denied { openSettings(kind); break }
            AVCaptureDevice.requestAccess(for: .video) { _ in self.refreshOnMain() }
        case .calendar:
            if status(kind) == .denied { openSettings(kind); break }
            eventStore.requestFullAccessToEvents { _, _ in self.refreshOnMain() }
        case .bluetooth:
            if status(kind) == .denied { openSettings(kind); break }
            bluetoothManager = CBCentralManager(delegate: self, queue: nil)
        case .location:
            if status(kind) == .denied { openSettings(kind); break }
            locationManager.requestWhenInUseAuthorization()
        case .automation:
            requestAutomation()
        case .focus:
            if status(kind) == .denied { openSettings(kind); break }
            INFocusStatusCenter.default.requestAuthorization { _ in self.refreshOnMain() }
        case .fullDisk:
            openSettings(kind)
        case .files:
            UserDefaults.standard.set(true, forKey: filesRequestedKey)
            // 폴더에 처음 접근할 때 시스템이 허용 여부를 묻는다.
            DispatchQueue.global().async {
                _ = Self.canRead(.downloadsDirectory)
                _ = Self.canRead(.desktopDirectory)
                self.refreshOnMain()
            }
        case .notifications:
            if status(kind) == .denied { openSettings(kind); break }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                self.refreshOnMain()
            }
        case .loginItem:
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                openSettings(kind)
            }
            refresh()
        }
    }

    func openSettings(_ kind: PermissionKind) {
        let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        let url = kind.settingsURL ?? fallback
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.open(fallback) }
    }

    func relaunch() {
        // 설정 도우미 프로세스에서는 본 앱을 다시 시작하게 하고 도우미는 끝낸다.
        if AppSettings.isHelper {
            Helper.sendToMain("restart")
            NSApp.terminate(nil)
            return
        }
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"$1\"", "sh", path]   // 경로는 인자로 (셸 주입 방지)
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - 자동화

    private func refreshAutomation() {
        DispatchQueue.global(qos: .utility).async {
            let results = Self.automationTargets.map { Self.automationStatus($0, ask: false) }
            let status: PermissionStatus
            if results.contains(.denied) { status = .denied }
            else if results.contains(.notDetermined) { status = .notDetermined }
            else if results.contains(.granted) { status = .granted }
            else { status = .needsAppRunning }
            DispatchQueue.main.async { self.statuses[.automation] = status }
        }
    }

    private func requestAutomation() {
        DispatchQueue.global(qos: .userInitiated).async {
            var anyRunning = false
            for id in Self.automationTargets {
                let s = Self.automationStatus(id, ask: true)
                if s != .needsAppRunning { anyRunning = true }
            }
            DispatchQueue.main.async {
                if !anyRunning {
                    let alert = NSAlert()
                    alert.messageText = T("Music 또는 Spotify를 먼저 실행하세요", "Open Music or Spotify first")
                    alert.informativeText = T("자동화 권한은 대상 앱이 실행 중일 때만 요청할 수 있습니다.", "Automation permission can only be requested while the target app is running.")
                    alert.runModal()
                }
                self.refresh()
            }
        }
    }

    /// AEDeterminePermissionToAutomateTarget은 대상 앱이 실행 중이어야 결과를 준다. 메인 스레드에서 호출하지 않는다.
    private static func automationStatus(_ bundleID: String, ask: Bool) -> PermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let err = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch err {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .needsAppRunning
        default: return .unknown
        }
    }

    // MARK: - 파일

    private func filesStatus() -> PermissionStatus {
        // 요청 전에는 폴더를 읽지 않는다(읽는 순간 시스템 창이 뜨므로).
        guard UserDefaults.standard.bool(forKey: filesRequestedKey) else { return .notDetermined }
        return Self.canRead(.downloadsDirectory) && Self.canRead(.desktopDirectory) ? .granted : .denied
    }

    private static func canRead(_ dir: FileManager.SearchPathDirectory) -> Bool {
        guard let url = FileManager.default.urls(for: dir, in: .userDomainMask).first else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// 전체 디스크 접근 여부. 보호된 경로를 실제로 열어 본다.
    /// macOS 버전에 따라 없는 경로(예: 사용자 TCC.db)가 있으므로, 존재하지 않는 경로(ENOENT)는 건너뛰고
    /// 존재하는 경로가 하나라도 열리면 허용, 존재하는데 막혀 있으면(EPERM/EACCES) 거부로 본다.
    /// 집중 모드 DB를 맨 앞에 두어 실제 기능이 쓰는 경로로 판단한다.
    static func hasFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/Library/DoNotDisturb/DB/Assertions.json",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari",
            home + "/Library/Mail",
        ]
        for path in candidates {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == ENOENT || errno == ENOTDIR { continue }   // 이 macOS에는 없는 경로
            return false   // 존재하지만 막혀 있음 → 권한 없음
        }
        return false
    }

    private func refreshOnMain() {
        DispatchQueue.main.async { self.refresh() }
    }

    // MARK: - 상태 매핑

    private static func map(_ s: AVAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private static func map(_ s: EKAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private static func map(_ s: CBManagerAuthorization) -> PermissionStatus {
        switch s {
        case .allowedAlways: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private static func map(_ s: CLAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorizedAlways: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private static func map(_ s: INFocusStatusAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private static func map(_ s: SMAppService.Status) -> PermissionStatus {
        switch s {
        case .enabled: return .granted
        case .requiresApproval: return .denied
        default: return .notDetermined
        }
    }

    // MARK: - 델리게이트

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { refresh() }

    func centralManagerDidUpdateState(_ central: CBCentralManager) { refresh() }
}
