import SwiftUI
import Combine

/// 앱 설정. SwiftUI는 @ObservedObject로, AppKit 코드는 AppSettings.shared로 읽는다.
/// 새 설정은 `@Setting("키", default: 값) var 이름: 타입` 한 줄이면 저장·다시 읽기·변경 알림까지 된다.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    let defaults = UserDefaults.standard
    /// @Published 없이 직접 알리므로 발행자를 직접 둔다
    let objectWillChange = ObservableObjectPublisher()

    private init() {}

    // MARK: - 일반

    /// 앱 언어. 실제 표시는 앱을 다시 시작할 때 바뀐다 (L10n.isEnglish).
    @Setting(L10n.languageKey, default: AppLanguage.system) var language: AppLanguage
    @Setting("showStatusItem", default: true) var showStatusItem: Bool
    @Setting("autoUpdate", default: true) var autoUpdate: Bool
    @Setting("memoryGuard", default: true) var memoryGuard: Bool
    /// 메모리 자동 최적화 기준 (MB)
    @Setting("memoryLimitMB", default: 70.0, sanitize: { min(150, max(70, $0)) }) var memoryLimitMB: Double
    @Setting("onboardingDone", default: false) var onboardingDone: Bool
    /// 설정 창 유리 배경: 흐림 정도와 투명도
    @Setting("settingsBlur", default: 1.0, sanitize: { min(1, max(0, $0)) }) var settingsBlur: Double
    @Setting("settingsTransparency", default: 0.35, sanitize: { min(0.9, max(0, $0)) }) var settingsTransparency: Double

    // MARK: - 노치 조작

    /// 일회성 알림의 기본 표시 시간. 기능별 표시 시간이 0이면 이 값을 쓴다.
    @Setting("transientDuration", default: 2.5) var transientDuration: Double
    @Setting("longPressDuration", default: 0.35) var longPressDuration: Double
    @Setting("forceTouchEnabled", default: true) var forceTouchEnabled: Bool
    @Setting("hapticStrength", default: HapticStrength.weak) var hapticStrength: HapticStrength
    @Setting("hoverPreview", default: true) var hoverPreview: Bool
    @Setting("hoverToOpen", default: false) var hoverToOpen: Bool

    // MARK: - 디스플레이

    /// 노치를 보일 디스플레이: one:<UUID> / builtIn / main / all (Displays 참고)
    @Setting("notchDisplays", read: AppSettings.savedNotchDisplays) var notchDisplays: String
    /// 디스플레이별 상시 표시 선택 (UUID → DisplayChoice). 없으면 주 디스플레이는 모든 항목, 나머지는 주 디스플레이를 따름.
    @Setting("displayContent", default: [:]) var displayContent: [String: String]
    /// 선택한 상시 표시가 비활성이면 주 디스플레이의 상시 표시를 대신 보인다
    @Setting("displayFallbackToMain", default: true) var displayFallbackToMain: Bool
    @Setting("alertScope", default: AlertScope.main) var alertScope: AlertScope
    /// 중요한 알림은 노치를 켠 모든 디스플레이에 보인다
    @Setting("criticalAlertsEnabled", default: true) var criticalAlertsEnabled: Bool
    /// 중요한 알림 구성은 기본 목록과의 차이만 저장한다
    @Setting("criticalAlertAdded", default: []) var criticalAlertAdded: [String]
    @Setting("criticalAlertRemoved", default: []) var criticalAlertRemoved: [String]

    var criticalAlerts: Set<String> {
        CriticalAlert.defaults.union(criticalAlertAdded).subtracting(criticalAlertRemoved)
    }

    var displayRules: DisplayRules {
        DisplayRules(content: displayContent, fallbackToMain: displayFallbackToMain, alertScopeAll: alertScope == .all,
                     criticalEnabled: criticalAlertsEnabled, critical: criticalAlerts,
                     monitor: aiUsagePinned ? effectiveMonitorContent : nil)
    }

    /// 저장된 값이 없으면 예전 설정을 이어 받는다. 신규 설치는 주 디스플레이, 예전 사용자는 지금 자리 그대로.
    private static func savedNotchDisplays(_ d: UserDefaults) -> String {
        if let saved = d.string(forKey: "notchDisplays") { return saved }
        if let old = d.string(forKey: "displayTarget") { return old }
        return d.bool(forKey: "onboardingDone") ? "builtIn" : "main"
    }

    // MARK: - 우선순위 · 홈

    /// 상시 표시 항목 우선순위 (앞일수록 먼저 노치에 표시)
    @Setting("persistentOrder", default: AppSettings.defaultPersistentOrder, sanitize: AppSettings.fixedPersistentOrder) var persistentOrder: [String]
    static let defaultPersistentOrder = ["call", "recording", "timer", "airdrop", "download", "media", "aiUsage", "resource", "battery", "calendar", "vpn", "hotspot", "focusPinned"]

    /// 새로 생긴 항목은 기본 순서에서 바로 앞 항목의 뒤에 넣는다 (예: 자원 사용량은 AI 사용량 아래). 통화는 기존 사용자도 맨 위로.
    static func fixedPersistentOrder(_ saved: [String]) -> [String] {
        var order = (saved.contains("call") ? [] : ["call"]) + saved.filter(defaultPersistentOrder.contains)
        for (i, key) in defaultPersistentOrder.enumerated() where !order.contains(key) {
            let before = defaultPersistentOrder[..<i].last(where: order.contains)
            order.insert(key, at: before.flatMap(order.firstIndex(of:)).map { $0 + 1 } ?? order.count)
        }
        return order
    }

    /// 홈 페이지 순서와 끈 기능
    @Setting("homeOrder", default: AppSettings.defaultHomeOrder, sanitize: AppSettings.fixedHomeOrder) var homeOrder: [String]
    @Setting("homeDisabled", default: []) var homeDisabled: [String]
    @Setting("trayMode", default: TrayMode.on) var trayMode: TrayMode
    static let defaultHomeOrder = ["camera", "timer", "usage", "resource", "memo", "calendar", "tray", "chat"]

    private static func fixedHomeOrder(_ saved: [String]) -> [String] {
        saved.filter(defaultHomeOrder.contains) + defaultHomeOrder.filter { !saved.contains($0) }
    }

    func isHomeFeatureOn(_ key: String) -> Bool {
        switch key {
        case "tray": return trayMode != .off
        case "chat": return chatEnabled
        default: return !homeDisabled.contains(key)
        }
    }

    /// 홈에 페이지로 보이는지 (트레이는 '홈에서 가림'이면 페이지만 숨김)
    func homeEnabled(_ option: HomeOption) -> Bool {
        option == .tray ? trayMode == .on : isHomeFeatureOn(option.key)
    }

    /// 스위치로 켜고 끄는 홈 기능 (트레이는 trayMode로 고른다)
    func setHomeFeature(_ key: String, on: Bool) {
        // 실시간 모니터링: 표시할 항목에 든 기능을 끄면 남은 쪽으로 바꾼다 (둘 다 → 하나)
        if !on, let feature = Self.monitorFeature(key) {
            let otherOn = isHomeFeatureOn(feature == .ai ? "resource" : "usage")
            monitorContent = MonitorLayout.contentAfterTurningOff(feature, current: monitorContent, otherOn: otherOn)
        }
        if key == "chat" {
            chatEnabled = on
        } else {
            homeDisabled = homeDisabled.filter { $0 != key } + (on ? [] : [key])
        }
    }

    private static func monitorFeature(_ key: String) -> MonitorFeature? {
        switch key {
        case "usage": return .ai
        case "resource": return .resource
        default: return nil
        }
    }

    // MARK: - 네트워크

    @Setting("netWifiPower", default: true) var netWifiPower: Bool
    @Setting("netWifiConnection", default: true) var netWifiConnection: Bool
    @Setting("netVPN", default: true) var netVPN: Bool
    @Setting("netHotspot", default: true) var netHotspot: Bool
    @Setting("netStyle", default: AlertStyle.compact) var netStyle: AlertStyle
    /// 0 = 일반 설정 따름
    @Setting("netDuration", default: 0.0) var netDuration: Double
    @Setting("hotspotPinned", default: false) var hotspotPinned: Bool
    @Setting("vpnPinned", default: false) var vpnPinned: Bool
    /// 핫스팟으로 간주할 SSID (쉼표 구분)
    @Setting("hotspotSSIDs", default: "") var hotspotSSIDs: String

    // MARK: - 블루투스

    @Setting("btEnabled", default: true) var btEnabled: Bool
    @Setting("btStyle", default: AlertStyle.compact) var btStyle: AlertStyle
    @Setting("btBattery", default: BatteryDisplay.percent) var btBattery: BatteryDisplay
    /// 알림을 끌 기기 이름 (쉼표 구분)
    @Setting("btBlocklist", default: "") var btBlocklist: String

    // MARK: - 집중 모드

    @Setting("focusEnabled", default: true) var focusEnabled: Bool
    @Setting("focusStyle", default: AlertStyle.compact) var focusStyle: AlertStyle
    /// 0 = 일반 설정 따름
    @Setting("focusDuration", default: 0.0) var focusDuration: Double
    @Setting("focusPinned", default: false) var focusPinned: Bool
    /// 표시하지 않을 모드 이름 (쉼표 구분)
    @Setting("focusExcluded", default: "") var focusExcluded: String

    // MARK: - 통화

    @Setting("callEnabled", default: true) var callEnabled: Bool

    // MARK: - 미디어

    @Setting("mediaSource", default: MediaSource.all) var mediaSource: MediaSource
    /// 일시정지 후 숨김까지 초 (0 = 숨기지 않음)
    @Setting("mediaHideAfterPause", default: 30.0) var mediaHideAfterPause: Double
    @Setting("mediaShowTrackChange", default: true) var mediaShowTrackChange: Bool
    /// 곡 변경 팝업을 Apple Music·Spotify에서만
    @Setting("mediaTrackChangeMusicOnly", default: true) var mediaTrackChangeMusicOnly: Bool

    // MARK: - 다운로드

    @Setting("downloadEnabled", default: true) var downloadEnabled: Bool
    @Setting("downloadStyle", default: ProgressStyle.ring) var downloadStyle: ProgressStyle
    /// 다운로드 폴더 (감시하고, 완료 후 Finder로 여는 곳)
    @Setting("downloadFolder", default: AppSettings.defaultDownloadFolder) var downloadFolder: String
    /// 추가 감시 폴더 (쉼표 구분 경로)
    @Setting("downloadFolders", default: "") var downloadFolders: String

    static var defaultDownloadFolder: String { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path }
    static var defaultRecordingFolder: String { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path }

    static func folderURL(_ path: String, fallback: String) -> URL {
        let p = (path.isEmpty ? fallback : (path as NSString).expandingTildeInPath)
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    // MARK: - 에어드랍·트레이

    @Setting("airdropStyle", default: ProgressStyle.ring) var airdropStyle: ProgressStyle
    @Setting("trayKeepCopies", default: false) var trayKeepCopies: Bool
    /// 자동 정리까지 분 (0 = 끄기)
    @Setting("trayCleanupMinutes", read: AppSettings.savedTrayCleanup) var trayCleanupMinutes: Double
    @Setting("dragZoneHeight", default: 120.0) var dragZoneHeight: Double
    /// 파일을 끌어왔을 때 먼저 보일 화면 (트레이·AI 채팅이 모두 켜져 있을 때)
    @Setting("fileDragPage", default: FileDragPage.tray) var fileDragPage: FileDragPage

    /// 저장된 값이 없으면 예전 일 단위 설정을 이어 받는다
    private static func savedTrayCleanup(_ d: UserDefaults) -> Double {
        if let minutes = d.object(forKey: "trayCleanupMinutes") as? Double { return minutes }
        return d.double(forKey: "trayCleanupDays") * 1440
    }

    // MARK: - 스크린샷

    @Setting("screenshotEnabled", default: true) var screenshotEnabled: Bool
    @Setting("screenshotSource", default: ScreenshotSource.clipboard) var screenshotSource: ScreenshotSource
    /// 비어 있으면 데스크탑
    @Setting("screenshotFolder", default: "") var screenshotFolder: String
    @Setting("screenshotJPEG", default: false) var screenshotJPEG: Bool
    @Setting("screenshotAutoClose", default: 10.0) var screenshotAutoClose: Double

    // MARK: - 화면 녹화

    @Setting("recordingEnabled", default: true) var recordingEnabled: Bool
    @Setting("recordingStyle", default: RecordingStyle.persistent) var recordingStyle: RecordingStyle
    /// 화면 녹화 저장 폴더 (완료 후 Finder로 여는 곳)
    @Setting("recordingFolder", default: AppSettings.defaultRecordingFolder) var recordingFolder: String

    // MARK: - 배터리

    @Setting("batteryChargerAlert", default: true) var batteryChargerAlert: Bool
    @Setting("batteryFullAlert", default: true) var batteryFullAlert: Bool
    @Setting("batteryLowAlert", default: true) var batteryLowAlert: Bool
    @Setting("batteryLowThreshold", default: 20.0) var batteryLowThreshold: Double
    @Setting("batteryStyle", default: AlertStyle.compact) var batteryStyle: AlertStyle
    /// 충전 중 상시 표시 (배터리 %·완충까지 남은 시간). 완충·충전 멈춤(어댑터로만 동작) 중에는 표시 안 함
    @Setting("batteryChargingPinned", default: true) var batteryChargingPinned: Bool

    // MARK: - HUD

    @Setting("hudVolume", default: true) var hudVolume: Bool
    @Setting("hudDisplay", default: true) var hudDisplay: Bool
    @Setting("hudKeyboard", default: true) var hudKeyboard: Bool
    @Setting("hudStyle", default: HUDStyle.bar) var hudStyle: HUDStyle
    @Setting("hudDuration", default: 1.5) var hudDuration: Double
    @Setting("hudOutputIcon", default: true) var hudOutputIcon: Bool
    /// 키 없이 바뀐 화면 밝기(제어 센터)도 표시
    @Setting("hudDisplayExternal", default: true) var hudDisplayExternal: Bool
    /// 키 없이 바뀐 키보드 밝기(제어 센터)도 표시
    @Setting("hudKeyboardExternal", default: true) var hudKeyboardExternal: Bool

    // MARK: - 잠금화면

    @Setting("lockNotchEnabled", default: true) var lockNotchEnabled: Bool
    @Setting("lockMediaWidget", default: true) var lockMediaWidget: Bool
    @Setting("lockHideTrackInfo", default: false) var lockHideTrackInfo: Bool
    @Setting("lyricsEnabled", default: true) var lyricsEnabled: Bool
    /// 외부 가사 DB(LRCLIB) 조회 동의. 곡 제목·아티스트가 외부로 전송되므로 기본 꺼짐.
    @Setting("lyricsOnline", default: false) var lyricsOnline: Bool
    /// 0 = 작게, 1 = 보통, 2 = 크게
    @Setting("lyricsSize", default: 1) var lyricsSize: Int

    // MARK: - 카메라 · 일정

    @Setting("cameraMirror", default: true) var cameraMirror: Bool
    /// 일정 시작 N분 전 알림 (0 = 끄기)
    @Setting("calendarAlertMinutes", default: 10.0) var calendarAlertMinutes: Double
    /// 다음(진행 중) 일정 상시 표시
    @Setting("calendarPinned", default: false) var calendarPinned: Bool

    // MARK: - 실시간 모니터링 (AI 사용량 + 자원 사용량)

    /// 노치에 상시 표시 (AI는 켜져 있을 때만 백그라운드에서 새로고침). 자원 사용량까지 함께 켜고 끈다.
    @Setting("aiUsagePinned", default: false) var aiUsagePinned: Bool
    /// 표시할 항목. 홈 기능으로 켠 것만 쓴다 (effectiveMonitorContent)
    @Setting("monitorContent", default: MonitorContent.ai) var monitorContent: MonitorContent
    @Setting("monitorExpand", default: MonitorExpand.follow) var monitorExpand: MonitorExpand
    /// 칸 선택은 모드마다 따로 기억한다
    @Setting("resourceLeft", default: MonitorMetric.cpu) var resourceLeft: MonitorMetric
    @Setting("resourceRight", default: MonitorMetric.mem) var resourceRight: MonitorMetric
    @Setting("bothLeft", default: MonitorMetric.aiPrimary) var bothLeft: MonitorMetric
    @Setting("bothRight", default: MonitorMetric.cpu) var bothRight: MonitorMetric
    /// 자원 사용량 새로고침 (초)
    @Setting("resourceRefreshSeconds", default: 2.0, sanitize: { [1, 2, 5, 10].contains($0) ? $0 : 2 }) var resourceRefreshSeconds: Double

    var monitorAIOn: Bool { isHomeFeatureOn("usage") }
    var monitorResourceOn: Bool { isHomeFeatureOn("resource") }

    /// 홈 기능으로 켜진 것으로 제한한 표시할 항목 (둘 다 꺼져 있으면 nil)
    var effectiveMonitorContent: MonitorContent? {
        MonitorLayout.effectiveContent(monitorContent, aiOn: monitorAIOn, resourceOn: monitorResourceOn)
    }

    /// 노치 양옆 칸 (표시할 항목이 없으면 nil)
    var monitorSlots: (left: MonitorMetric, right: MonitorMetric)? {
        guard let content = effectiveMonitorContent else { return nil }
        switch content {
        case .ai: return MonitorLayout.defaults(for: .ai)
        case .resource: return MonitorLayout.slots(.resource, left: resourceLeft, right: resourceRight)
        case .both: return MonitorLayout.slots(.both, left: bothLeft, right: bothRight)
        }
    }

    /// 자원 사용량·통합 활동의 칸 (디스플레이에서 직접 고른 경우도 있어 모드와 상관없이 쓴다)
    var resourceSlots: (left: MonitorMetric, right: MonitorMetric) { MonitorLayout.slots(.resource, left: resourceLeft, right: resourceRight) }
    var bothSlots: (left: MonitorMetric, right: MonitorMetric) { MonitorLayout.slots(.both, left: bothLeft, right: bothRight) }

    /// 지금 게시해야 할 실시간 모니터링 활동
    var monitorKindsNeeded: Set<ActivityKind> { displayRules.neededMonitorKinds(aiOn: monitorAIOn, resourceOn: monitorResourceOn) }

    /// 지금 모드의 칸 하나를 바꾼다. 반대편과 같은 값은 받지 않는다.
    func setMonitorSlot(_ metric: MonitorMetric, left: Bool) {
        guard let content = effectiveMonitorContent, content != .ai, let slots = monitorSlots,
              metric != (left ? slots.right : slots.left), MonitorLayout.choices(for: content).contains(metric) else { return }
        switch (content, left) {
        case (.resource, true): resourceLeft = metric
        case (.resource, false): resourceRight = metric
        case (_, true): bothLeft = metric
        case (_, false): bothRight = metric
        }
        // 반대편이 기본값으로 풀려 있던 경우 그 값도 함께 저장해 화면과 저장값을 맞춘다
        if content == .resource { if left { resourceRight = slots.right } else { resourceLeft = slots.left } }
        else { if left { bothRight = slots.right } else { bothLeft = slots.left } }
    }

    var monitorExpandContent: MonitorContent? {
        MonitorLayout.expandContent(monitorExpand, content: effectiveMonitorContent, aiOn: monitorAIOn, resourceOn: monitorResourceOn)
    }

    // MARK: - AI 사용량

    @Setting("aiUsageStyle", default: UsageStyle.text) var aiUsageStyle: UsageStyle
    /// 상시 표시할 서비스 (AIService rawValue)
    @Setting("aiUsageService", default: "claude") var aiUsageService: String
    /// 새로고침 간격 (분). 예전 15~60분 값은 10분으로.
    @Setting("aiRefreshMinutes", default: 5.0, sanitize: { [1, 2, 5, 10].contains($0) ? $0 : 10 }) var aiRefreshMinutes: Double
    /// 로그인해 연결한 서비스 (쉼표 구분 rawValue, 로그인 창이 기록)
    @Setting("aiConnected", default: "") var aiConnected: String

    // MARK: - AI 채팅

    /// 노치 홈의 AI 채팅 페이지 (외부로 질문을 보내는 기능이라 기본 꺼짐)
    @Setting("chatEnabled", default: false) var chatEnabled: Bool
    /// 노치를 나갔다가 채팅 페이지로 돌아왔을 때 보여 줄 화면
    @Setting("chatReopen", default: ChatReopen.lastAnswer) var chatReopen: ChatReopen
    /// 모르는 내용·최근 일은 웹 검색으로 답하게 한다 (서비스의 검색 도구, 별도 요금이 붙을 수 있음)
    @Setting("chatWebSearch", default: true) var chatWebSearch: Bool
    /// 사용자가 적은 답변 지침 (모든 서비스의 공통 지시 뒤에 붙는다).
    /// 질문할 때 저장값을 직접 읽으므로 본 앱에 알리지 않는다 (글자마다 본 앱의 설정을 다시 읽지 않게)
    @Setting(AppSettings.chatInstructionsKey, default: "", notifiesMainApp: false) var chatInstructions: String
    static let chatInstructionsKey = "chatInstructions"
    static let chatInstructionsLimit = 2000
    @Setting("chatService", default: ChatService.claude) var chatService: ChatService
    /// 서비스별 모델 (비어 있으면 그 서비스의 기본 모델)
    @Setting("chatModelClaude", default: "") var chatModelClaude: String
    @Setting("chatModelOpenAI", default: "") var chatModelOpenAI: String
    @Setting("chatModelGemini", default: "") var chatModelGemini: String

    func chatModel(for service: ChatService) -> String {
        switch service {
        case .claude: return chatModelClaude.isEmpty ? service.defaultModel : chatModelClaude
        case .openai: return chatModelOpenAI
        case .gemini: return chatModelGemini
        }
    }

    func setChatModel(_ model: String, for service: ChatService) {
        switch service {
        case .claude: chatModelClaude = model
        case .openai: chatModelOpenAI = model
        case .gemini: chatModelGemini = model
        }
    }

    // MARK: - Claude Code · Codex

    /// 작업 완료 알림
    @Setting("agentAlerts", default: true) var agentAlerts: Bool
    /// 작업 완료 알림 형태 (상세: 끝난 작업 이름까지)
    @Setting("agentStyle", default: AlertStyle.compact) var agentStyle: AlertStyle

    // MARK: - 도우미

    /// 0이면 nil(일반 설정 따름).
    static func duration(_ value: Double) -> TimeInterval? { value > 0 ? value : nil }

    static func list(_ csv: String) -> [String] {
        csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - 프로세스 간 동기화

    /// 설정 창은 별도 도우미 프로세스에서 열린다(창을 닫으면 프로세스째 메모리가 반환됨).
    /// 도우미가 값을 바꾸면 본 앱에 알려 다시 읽게 한다.
    static var isHelper = false
    static let changedNotification = Notification.Name("com.dynamicmacnotch.app.settingsChanged")

    private lazy var slots: [SettingSlot] = Mirror(reflecting: self).children.compactMap { $0.value as? SettingSlot }
    var settingCount: Int { slots.count }

    /// 다른 프로세스가 바꾼 값을 다시 읽는다. 실제로 바뀐 설정만 알림을 보낸다.
    func reload() {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        slots.forEach { $0.refresh(from: defaults, owner: self) }
    }

    func didSave(key: String, notifiesMainApp: Bool) {
        guard Self.isHelper, notifiesMainApp else { return }
        DistributedNotificationCenter.default().postNotificationName(Self.changedNotification, object: key,
                                                                     userInfo: nil, deliverImmediately: true)
    }
}
