import SwiftUI

enum HapticStrength: String, CaseIterable, Identifiable {
    case off, weak, strong
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return T("끄기", "Off")
        case .weak: return T("약", "Light")
        case .strong: return T("강", "Strong")
        }
    }
}

enum AlertStyle: String, CaseIterable, Identifiable {
    case compact, detail
    var id: String { rawValue }
    var label: String { self == .compact ? T("컴팩트", "Compact") : T("상세", "Detailed") }
}

enum BatteryDisplay: String, CaseIterable, Identifiable {
    case percent, ring, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .percent: return T("백분율", "Percent")
        case .ring: return T("원형", "Ring")
        case .both: return T("둘 다", "Both")
        }
    }
}

enum HUDStyle: String, CaseIterable, Identifiable {
    case number, bar, ring
    var id: String { rawValue }
    var label: String {
        switch self {
        case .number: return T("숫자", "Number")
        case .bar: return T("가로 바", "Bar")
        case .ring: return T("원형", "Ring")
        }
    }
}

enum ProgressStyle: String, CaseIterable, Identifiable {
    case percent, ring
    var id: String { rawValue }
    var label: String { self == .percent ? T("백분율", "Percent") : T("원형", "Ring") }
}

enum ScreenshotSource: String, CaseIterable, Identifiable {
    case clipboard, file, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .clipboard: return T("클립보드", "Clipboard")
        case .file: return T("파일", "File")
        case .both: return T("둘 다", "Both")
        }
    }
}

/// UserDefaults에 저장되는 앱 설정. SwiftUI는 @ObservedObject로, AppKit 코드는 AppSettings.shared로 읽는다.
/// 화면 녹화 표시: 잠깐 알림 후 들어감 / 녹화 내내 노치에 표시(왼쪽 녹화 시간)
enum RecordingStyle: String, CaseIterable, Identifiable {
    case brief, persistent
    var id: String { rawValue }
    var label: String { self == .brief ? T("잠깐 알림", "Brief Alert") : T("계속 표시 (녹화 시간)", "Keep Showing (Elapsed Time)") }
}

/// 에어드랍·트레이: 사용 / 노치 홈에서 가림(파일을 끌어오면 여전히 동작) / 끄기(끌어와도 동작 안 함)
enum TrayMode: String, CaseIterable, Identifiable {
    case on, hidden, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .on: return T("사용", "On")
        case .hidden: return T("노치에서 가림", "Hide in Notch")
        case .off: return T("끄기", "Off")
        }
    }
}

/// AI 채팅 페이지로 돌아왔을 때: 마지막 답변 / 처음 화면(입력 칸만, 목록 닫힘)
enum ChatReopen: String, CaseIterable, Identifiable {
    case lastAnswer, fresh
    var id: String { rawValue }
    var label: String { self == .lastAnswer ? T("마지막 답변", "Last Answer") : T("처음 화면", "New Chat Screen") }
}

/// AI 사용량 표시 형태
enum UsageStyle: String, CaseIterable, Identifiable {
    case text, ring
    var id: String { rawValue }
    var label: String { self == .text ? T("텍스트", "Text") : T("원형", "Ring") }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    // 일반
    /// 노치를 보일 디스플레이: one:<UUID> / builtIn / main (Displays 참고)
    @Published var notchDisplays: String { didSet { save(notchDisplays, "notchDisplays") } }

    /// 저장된 값이 없으면 예전 설정을 이어 받는다. 신규 설치는 주 디스플레이, 예전 사용자는 지금 자리 그대로.
    private static func savedNotchDisplays(_ d: UserDefaults) -> String {
        if let saved = d.string(forKey: "notchDisplays") { return saved }
        if let old = d.string(forKey: "displayTarget") { return old }
        return d.bool(forKey: "onboardingDone") ? "builtIn" : "main"
    }
    /// 앱 언어. 실제 표시는 앱을 다시 시작할 때 바뀐다 (L10n.isEnglish).
    @Published var language: AppLanguage { didSet { save(language.rawValue, L10n.languageKey) } }
    @Published var transientDuration: Double { didSet { save(transientDuration, "transientDuration") } }
    @Published var showStatusItem: Bool { didSet { save(showStatusItem, "showStatusItem") } }
    @Published var autoUpdate: Bool { didSet { save(autoUpdate, "autoUpdate") } }
    @Published var memoryGuard: Bool { didSet { save(memoryGuard, "memoryGuard") } }
    /// 메모리 자동 최적화 기준 (MB, 70~150)
    @Published var memoryLimitMB: Double { didSet { save(memoryLimitMB, "memoryLimitMB") } }
    @Published var onboardingDone: Bool { didSet { save(onboardingDone, "onboardingDone") } }
    /// 설정 창 유리 배경: 흐림 정도(0~1)와 투명도(0~0.9)
    @Published var settingsBlur: Double { didSet { save(settingsBlur, "settingsBlur") } }
    @Published var settingsTransparency: Double { didSet { save(settingsTransparency, "settingsTransparency") } }

    // 상호작용
    @Published var longPressDuration: Double { didSet { save(longPressDuration, "longPressDuration") } }
    @Published var forceTouchEnabled: Bool { didSet { save(forceTouchEnabled, "forceTouchEnabled") } }
    @Published var hapticStrength: HapticStrength { didSet { save(hapticStrength.rawValue, "hapticStrength") } }
    @Published var hoverPreview: Bool { didSet { save(hoverPreview, "hoverPreview") } }
    @Published var hoverToOpen: Bool { didSet { save(hoverToOpen, "hoverToOpen") } }

    // 배터리
    @Published var batteryChargerAlert: Bool { didSet { save(batteryChargerAlert, "batteryChargerAlert") } }
    @Published var batteryFullAlert: Bool { didSet { save(batteryFullAlert, "batteryFullAlert") } }
    @Published var batteryLowAlert: Bool { didSet { save(batteryLowAlert, "batteryLowAlert") } }
    @Published var batteryLowThreshold: Double { didSet { save(batteryLowThreshold, "batteryLowThreshold") } }

    // 네트워크 (가이드라인 5.3)
    @Published var netWifiPower: Bool { didSet { save(netWifiPower, "netWifiPower") } }
    @Published var netWifiConnection: Bool { didSet { save(netWifiConnection, "netWifiConnection") } }
    @Published var netVPN: Bool { didSet { save(netVPN, "netVPN") } }
    @Published var netHotspot: Bool { didSet { save(netHotspot, "netHotspot") } }
    /// 0 = 일반 설정 따름
    @Published var netDuration: Double { didSet { save(netDuration, "netDuration") } }
    @Published var hotspotPinned: Bool { didSet { save(hotspotPinned, "hotspotPinned") } }
    /// VPN 연결 중 상시 표시 (아이콘만)
    @Published var vpnPinned: Bool { didSet { save(vpnPinned, "vpnPinned") } }
    /// 핫스팟으로 간주할 SSID (쉼표 구분)
    @Published var hotspotSSIDs: String { didSet { save(hotspotSSIDs, "hotspotSSIDs") } }

    // 블루투스 (5.4)
    @Published var btEnabled: Bool { didSet { save(btEnabled, "btEnabled") } }
    @Published var btStyle: AlertStyle { didSet { save(btStyle.rawValue, "btStyle") } }
    @Published var btBattery: BatteryDisplay { didSet { save(btBattery.rawValue, "btBattery") } }
    @Published var btShowDisconnect: Bool { didSet { save(btShowDisconnect, "btShowDisconnect") } }
    /// 알림을 끌 기기 이름 (쉼표 구분)
    @Published var btBlocklist: String { didSet { save(btBlocklist, "btBlocklist") } }

    // 집중 모드 (5.5)
    @Published var focusEnabled: Bool { didSet { save(focusEnabled, "focusEnabled") } }
    @Published var focusDuration: Double { didSet { save(focusDuration, "focusDuration") } }
    @Published var focusPinned: Bool { didSet { save(focusPinned, "focusPinned") } }
    /// 표시하지 않을 모드 이름 (쉼표 구분)
    @Published var focusExcluded: String { didSet { save(focusExcluded, "focusExcluded") } }

    // HUD (5.9)
    @Published var hudVolume: Bool { didSet { save(hudVolume, "hudVolume") } }
    @Published var hudDisplay: Bool { didSet { save(hudDisplay, "hudDisplay") } }
    @Published var hudKeyboard: Bool { didSet { save(hudKeyboard, "hudKeyboard") } }
    @Published var hudStyle: HUDStyle { didSet { save(hudStyle.rawValue, "hudStyle") } }
    @Published var hudDuration: Double { didSet { save(hudDuration, "hudDuration") } }
    @Published var hudOutputIcon: Bool { didSet { save(hudOutputIcon, "hudOutputIcon") } }
    /// 키 없이 바뀐 화면 밝기(제어 센터·자동 밝기)도 표시
    @Published var hudDisplayExternal: Bool { didSet { save(hudDisplayExternal, "hudDisplayExternal") } }
    /// 키 없이 바뀐 키보드 밝기(제어 센터)도 표시
    @Published var hudKeyboardExternal: Bool { didSet { save(hudKeyboardExternal, "hudKeyboardExternal") } }

    // 잠깐 표시 스타일 (컴팩트: 좌우로만 넓어지며 아이콘+짧은 단어 / 상세: 좌우·아래로 커지며 이름 등 세부 정보)
    @Published var netStyle: AlertStyle { didSet { save(netStyle.rawValue, "netStyle") } }
    @Published var focusStyle: AlertStyle { didSet { save(focusStyle.rawValue, "focusStyle") } }
    @Published var batteryStyle: AlertStyle { didSet { save(batteryStyle.rawValue, "batteryStyle") } }

    /// 상시 표시 항목 우선순위 (앞일수록 먼저 노치에 표시)
    @Published var persistentOrder: [String] { didSet { save(persistentOrder, "persistentOrder") } }
    static let defaultPersistentOrder = ["call", "recording", "timer", "airdrop", "download", "media", "aiUsage", "battery", "calendar", "vpn", "hotspot", "focusPinned"]

    // 미디어 (5.7)
    @Published var mediaSource: MediaSource { didSet { save(mediaSource.rawValue, "mediaSource") } }
    /// 일시정지 후 숨김까지 초 (0 = 숨기지 않음)
    @Published var mediaHideAfterPause: Double { didSet { save(mediaHideAfterPause, "mediaHideAfterPause") } }
    @Published var mediaShowTrackChange: Bool { didSet { save(mediaShowTrackChange, "mediaShowTrackChange") } }
    /// 곡 변경 팝업을 Apple Music·Spotify에서만
    @Published var mediaTrackChangeMusicOnly: Bool { didSet { save(mediaTrackChangeMusicOnly, "mediaTrackChangeMusicOnly") } }

    // 다운로드 (5.8)
    @Published var downloadEnabled: Bool { didSet { save(downloadEnabled, "downloadEnabled") } }
    @Published var downloadStyle: ProgressStyle { didSet { save(downloadStyle.rawValue, "downloadStyle") } }
    /// 추가 감시 폴더 (쉼표 구분 경로)
    @Published var downloadFolders: String { didSet { save(downloadFolders, "downloadFolders") } }
    /// 다운로드 폴더 (감시하고, 완료 후 Finder로 여는 곳). 기본은 다운로드 폴더
    @Published var downloadFolder: String { didSet { save(downloadFolder, "downloadFolder") } }
    /// 화면 녹화 저장 폴더 (완료 후 Finder로 여는 곳). 기본은 데스크탑
    @Published var recordingFolder: String { didSet { save(recordingFolder, "recordingFolder") } }

    static var defaultDownloadFolder: String { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path }
    static var defaultRecordingFolder: String { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path }

    static func folderURL(_ path: String, fallback: String) -> URL {
        let p = (path.isEmpty ? fallback : (path as NSString).expandingTildeInPath)
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    // 트레이·에어드랍 (5.2)
    @Published var trayKeepCopies: Bool { didSet { save(trayKeepCopies, "trayKeepCopies") } }
    /// 자동 정리 일수 (0 = 끄기)
    @Published var trayCleanupDays: Double { didSet { save(trayCleanupDays, "trayCleanupDays") } }
    @Published var dragZoneHeight: Double { didSet { save(dragZoneHeight, "dragZoneHeight") } }
    /// 파일을 끌어왔을 때 먼저 보일 화면 (트레이·AI 채팅이 모두 켜져 있을 때)
    @Published var fileDragPage: String { didSet { save(fileDragPage, "fileDragPage") } }
    @Published var airdropStyle: ProgressStyle { didSet { save(airdropStyle.rawValue, "airdropStyle") } }

    // 스크린샷 (5.11)
    @Published var screenshotEnabled: Bool { didSet { save(screenshotEnabled, "screenshotEnabled") } }
    @Published var screenshotSource: ScreenshotSource { didSet { save(screenshotSource.rawValue, "screenshotSource") } }
    /// 비어 있으면 데스크탑
    @Published var screenshotFolder: String { didSet { save(screenshotFolder, "screenshotFolder") } }
    @Published var screenshotJPEG: Bool { didSet { save(screenshotJPEG, "screenshotJPEG") } }
    @Published var screenshotAutoClose: Double { didSet { save(screenshotAutoClose, "screenshotAutoClose") } }

    // 화면 녹화·카메라·캘린더
    @Published var recordingEnabled: Bool { didSet { save(recordingEnabled, "recordingEnabled") } }
    @Published var callEnabled: Bool { didSet { save(callEnabled, "callEnabled") } }
    @Published var recordingStyle: RecordingStyle { didSet { save(recordingStyle.rawValue, "recordingStyle") } }
    @Published var cameraMirror: Bool { didSet { save(cameraMirror, "cameraMirror") } }
    /// 일정 시작 N분 전 알림 (0 = 끄기)
    @Published var calendarAlertMinutes: Double { didSet { save(calendarAlertMinutes, "calendarAlertMinutes") } }

    // 잠금화면 (5.12, 5.13)
    @Published var lockNotchEnabled: Bool { didSet { save(lockNotchEnabled, "lockNotchEnabled") } }
    @Published var lockMediaWidget: Bool { didSet { save(lockMediaWidget, "lockMediaWidget") } }
    @Published var lockHideTrackInfo: Bool { didSet { save(lockHideTrackInfo, "lockHideTrackInfo") } }
    @Published var lockWidgetBottom: Bool { didSet { save(lockWidgetBottom, "lockWidgetBottom") } }
    @Published var lyricsEnabled: Bool { didSet { save(lyricsEnabled, "lyricsEnabled") } }
    /// 외부 가사 DB(LRCLIB) 조회 동의. 곡 제목·아티스트가 외부로 전송되므로 기본 꺼짐.
    @Published var lyricsOnline: Bool { didSet { save(lyricsOnline, "lyricsOnline") } }
    /// 0 = 작게, 1 = 보통, 2 = 크게
    @Published var lyricsSize: Int { didSet { save(lyricsSize, "lyricsSize") } }

    // AI 사용량 (Claude · ChatGPT · Gemini)
    /// 노치에 상시 표시 (켜져 있을 때만 백그라운드에서 새로고침)
    @Published var aiUsagePinned: Bool { didSet { save(aiUsagePinned, "aiUsagePinned") } }
    @Published var aiUsageStyle: UsageStyle { didSet { save(aiUsageStyle.rawValue, "aiUsageStyle") } }
    /// 상시 표시할 서비스 (AIService rawValue)
    @Published var aiUsageService: String { didSet { save(aiUsageService, "aiUsageService") } }
    /// 노치 홈의 AI 채팅 페이지 (외부로 질문을 보내는 기능이라 기본 꺼짐)
    @Published var chatEnabled: Bool { didSet { save(chatEnabled, "chatEnabled") } }
    /// 노치를 나갔다가 채팅 페이지로 돌아왔을 때 보여 줄 화면
    @Published var chatReopen: ChatReopen { didSet { save(chatReopen.rawValue, "chatReopen") } }
    /// 모르는 내용·최근 일은 웹 검색으로 답하게 한다 (서비스의 검색 도구, 별도 요금이 붙을 수 있음)
    @Published var chatWebSearch: Bool { didSet { save(chatWebSearch, "chatWebSearch") } }
    /// 사용자가 적은 답변 지침 (모든 서비스의 공통 지시 뒤에 붙는다)
    /// 질문할 때 저장값을 직접 읽으므로 본 앱에 알리지 않는다 (글자마다 본 앱의 설정을 다시 읽지 않게)
    @Published var chatInstructions: String {
        didSet {
            guard !loading else { return }
            defaults.set(chatInstructions, forKey: AppSettings.chatInstructionsKey)
        }
    }
    static let chatInstructionsKey = "chatInstructions"
    static let chatInstructionsLimit = 2000
    @Published var chatService: ChatService { didSet { save(chatService.rawValue, "chatService") } }
    /// 서비스별 모델 (비어 있으면 그 서비스의 기본 모델)
    @Published var chatModelClaude: String { didSet { save(chatModelClaude, "chatModelClaude") } }
    @Published var chatModelOpenAI: String { didSet { save(chatModelOpenAI, "chatModelOpenAI") } }
    @Published var chatModelGemini: String { didSet { save(chatModelGemini, "chatModelGemini") } }

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
    /// 새로고침 간격 (분)
    @Published var aiRefreshMinutes: Double { didSet { save(aiRefreshMinutes, "aiRefreshMinutes") } }
    /// 충전 중 상시 표시 (배터리 %·완충까지 남은 시간). 완충·충전 멈춤(어댑터로만 동작) 중에는 표시 안 함
    @Published var batteryChargingPinned: Bool { didSet { save(batteryChargingPinned, "batteryChargingPinned") } }
    /// 다음(진행 중) 일정 상시 표시
    @Published var calendarPinned: Bool { didSet { save(calendarPinned, "calendarPinned") } }

    // 기본 노치 (홈) 기능: 순서, 끈 기능, 트레이 방식
    @Published var homeOrder: [String] { didSet { save(homeOrder, "homeOrder") } }
    @Published var homeDisabled: [String] { didSet { save(homeDisabled, "homeDisabled") } }
    @Published var trayMode: TrayMode { didSet { save(trayMode.rawValue, "trayMode") } }
    static let defaultHomeOrder = ["camera", "timer", "usage", "memo", "calendar", "tray", "chat"]

    func isHomeFeatureOn(_ key: String) -> Bool {
        switch key {
        case "tray": return trayMode != .off
        case "chat": return chatEnabled
        default: return !homeDisabled.contains(key)
        }
    }

    /// 홈에 페이지로 보이는지 (트레이는 '노치에서 가림'이면 페이지만 숨김)
    func homeEnabled(_ option: HomeOption) -> Bool {
        switch option {
        case .tray: return trayMode == .on
        case .chat: return chatEnabled
        default: return !homeDisabled.contains(option.key)
        }
    }

    /// Claude Code·Codex 작업 완료 알림
    @Published var agentAlerts: Bool { didSet { save(agentAlerts, "agentAlerts") } }
    /// 작업 완료 알림 형태 (상세: 끝난 작업 이름까지)
    @Published var agentStyle: AlertStyle { didSet { save(agentStyle.rawValue, "agentStyle") } }
    /// 로그인해 연결한 서비스 (쉼표 구분 rawValue, 로그인 창이 기록)
    @Published var aiConnected: String { didSet { save(aiConnected, "aiConnected") } }

    /// 0이면 nil(일반 설정 따름).
    static func duration(_ value: Double) -> TimeInterval? { value > 0 ? value : nil }

    static func list(_ csv: String) -> [String] {
        csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private init() {
        let d = UserDefaults.standard
        func value<T>(_ key: String, _ fallback: T) -> T { d.object(forKey: key) as? T ?? fallback }

        notchDisplays = Self.savedNotchDisplays(d)
        language = AppLanguage(rawValue: value(L10n.languageKey, "")) ?? .system
        transientDuration = value("transientDuration", 2.5)
        showStatusItem = value("showStatusItem", true)
        autoUpdate = value("autoUpdate", true)
        memoryGuard = value("memoryGuard", true)
        memoryLimitMB = min(150, max(70, value("memoryLimitMB", 70.0)))
        onboardingDone = value("onboardingDone", false)
        settingsBlur = min(1, max(0, value("settingsBlur", 1.0)))
        settingsTransparency = min(0.9, max(0, value("settingsTransparency", 0.35)))

        longPressDuration = value("longPressDuration", 0.35)
        forceTouchEnabled = value("forceTouchEnabled", true)
        hapticStrength = HapticStrength(rawValue: value("hapticStrength", "")) ?? .weak
        hoverPreview = value("hoverPreview", true)
        hoverToOpen = value("hoverToOpen", false)

        batteryChargerAlert = value("batteryChargerAlert", true)
        batteryFullAlert = value("batteryFullAlert", true)
        batteryLowAlert = value("batteryLowAlert", true)
        batteryLowThreshold = value("batteryLowThreshold", 20.0)

        netWifiPower = value("netWifiPower", true)
        netWifiConnection = value("netWifiConnection", true)
        netVPN = value("netVPN", true)
        netHotspot = value("netHotspot", true)
        netDuration = value("netDuration", 0.0)
        hotspotPinned = value("hotspotPinned", false)
        vpnPinned = value("vpnPinned", false)
        hotspotSSIDs = value("hotspotSSIDs", "")

        btEnabled = value("btEnabled", true)
        btStyle = AlertStyle(rawValue: value("btStyle", "")) ?? .compact
        btBattery = BatteryDisplay(rawValue: value("btBattery", "")) ?? .percent
        btShowDisconnect = value("btShowDisconnect", false)
        btBlocklist = value("btBlocklist", "")

        focusEnabled = value("focusEnabled", true)
        focusDuration = value("focusDuration", 0.0)
        focusPinned = value("focusPinned", false)
        focusExcluded = value("focusExcluded", "")

        hudVolume = value("hudVolume", true)
        hudDisplay = value("hudDisplay", true)
        hudKeyboard = value("hudKeyboard", true)
        hudStyle = HUDStyle(rawValue: value("hudStyle", "")) ?? .bar
        hudDuration = value("hudDuration", 1.5)
        hudOutputIcon = value("hudOutputIcon", true)
        hudDisplayExternal = value("hudDisplayExternal", true)
        hudKeyboardExternal = value("hudKeyboardExternal", true)

        netStyle = AlertStyle(rawValue: value("netStyle", "")) ?? .compact
        focusStyle = AlertStyle(rawValue: value("focusStyle", "")) ?? .compact
        batteryStyle = AlertStyle(rawValue: value("batteryStyle", "")) ?? .compact
        let savedOrder: [String] = value("persistentOrder", AppSettings.defaultPersistentOrder)
        // 새로 생긴 항목은 기본 순서대로 뒤에 붙인다.
        persistentOrder = (savedOrder.contains("call") ? [] : ["call"])   // 통화는 기존 사용자도 맨 위로
            + savedOrder.filter { AppSettings.defaultPersistentOrder.contains($0) }
            + AppSettings.defaultPersistentOrder.filter { !savedOrder.contains($0) && $0 != "call" }

        lockNotchEnabled = value("lockNotchEnabled", true)
        lockMediaWidget = value("lockMediaWidget", true)
        lockHideTrackInfo = value("lockHideTrackInfo", false)
        lockWidgetBottom = value("lockWidgetBottom", false)
        lyricsEnabled = value("lyricsEnabled", true)
        lyricsOnline = value("lyricsOnline", false)
        lyricsSize = value("lyricsSize", 1)
        aiUsagePinned = value("aiUsagePinned", false)
        aiUsageStyle = UsageStyle(rawValue: value("aiUsageStyle", "")) ?? .text
        aiUsageService = value("aiUsageService", "claude")
        chatEnabled = value("chatEnabled", false)
        chatWebSearch = value("chatWebSearch", true)
        chatInstructions = value(AppSettings.chatInstructionsKey, "")
        chatReopen = ChatReopen(rawValue: value("chatReopen", "")) ?? .lastAnswer
        chatService = ChatService(rawValue: value("chatService", "")) ?? .claude
        chatModelClaude = value("chatModelClaude", "")
        chatModelOpenAI = value("chatModelOpenAI", "")
        chatModelGemini = value("chatModelGemini", "")
        // 1·2·5·10분 중 하나 (예전 15~60분 값은 10분으로)
        aiRefreshMinutes = [1.0, 2.0, 5.0, 10.0].contains(value("aiRefreshMinutes", 5.0)) ? value("aiRefreshMinutes", 5.0) : 10
        aiConnected = value("aiConnected", "")
        agentAlerts = value("agentAlerts", true)
        agentStyle = AlertStyle(rawValue: value("agentStyle", "")) ?? .compact
        batteryChargingPinned = value("batteryChargingPinned", true)
        calendarPinned = value("calendarPinned", false)
        // 새로 생긴 홈 기능은 기본 순서대로 뒤에 붙인다
        let savedHome: [String] = value("homeOrder", AppSettings.defaultHomeOrder)
        homeOrder = savedHome.filter(AppSettings.defaultHomeOrder.contains) + AppSettings.defaultHomeOrder.filter { !savedHome.contains($0) }
        homeDisabled = value("homeDisabled", [String]())
        trayMode = TrayMode(rawValue: value("trayMode", "")) ?? .on

        mediaSource = MediaSource(rawValue: value("mediaSource", "")) ?? .all
        mediaHideAfterPause = value("mediaHideAfterPause", 30.0)
        mediaShowTrackChange = value("mediaShowTrackChange", true)
        mediaTrackChangeMusicOnly = value("mediaTrackChangeMusicOnly", true)

        downloadEnabled = value("downloadEnabled", true)
        downloadStyle = ProgressStyle(rawValue: value("downloadStyle", "")) ?? .ring
        downloadFolders = value("downloadFolders", "")
        downloadFolder = value("downloadFolder", AppSettings.defaultDownloadFolder)
        recordingFolder = value("recordingFolder", AppSettings.defaultRecordingFolder)

        trayKeepCopies = value("trayKeepCopies", false)
        trayCleanupDays = value("trayCleanupDays", 0.0)
        dragZoneHeight = value("dragZoneHeight", 120.0)
        fileDragPage = value("fileDragPage", "tray")
        airdropStyle = ProgressStyle(rawValue: value("airdropStyle", "")) ?? .ring

        screenshotEnabled = value("screenshotEnabled", true)
        screenshotSource = ScreenshotSource(rawValue: value("screenshotSource", "")) ?? .clipboard
        screenshotFolder = value("screenshotFolder", "")
        screenshotJPEG = value("screenshotJPEG", false)
        screenshotAutoClose = value("screenshotAutoClose", 10.0)

        recordingEnabled = value("recordingEnabled", true)
        callEnabled = value("callEnabled", true)
        recordingStyle = RecordingStyle(rawValue: value("recordingStyle", "")) ?? .persistent
        cameraMirror = value("cameraMirror", true)
        calendarAlertMinutes = value("calendarAlertMinutes", 10.0)
    }

    /// 다른 프로세스(설정 창 도우미)가 바꾼 값을 다시 읽는다. 읽는 동안에는 저장·알림을 하지 않는다.
    func reload() {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        loading = true
        defer { loading = false }
        let d = UserDefaults.standard
        func value<T>(_ key: String, _ fallback: T) -> T { d.object(forKey: key) as? T ?? fallback }

        notchDisplays = Self.savedNotchDisplays(d)
        language = AppLanguage(rawValue: value(L10n.languageKey, "")) ?? .system
        transientDuration = value("transientDuration", 2.5)
        showStatusItem = value("showStatusItem", true)
        autoUpdate = value("autoUpdate", true)
        memoryGuard = value("memoryGuard", true)
        memoryLimitMB = min(150, max(70, value("memoryLimitMB", 70.0)))
        onboardingDone = value("onboardingDone", false)
        settingsBlur = min(1, max(0, value("settingsBlur", 1.0)))
        settingsTransparency = min(0.9, max(0, value("settingsTransparency", 0.35)))

        longPressDuration = value("longPressDuration", 0.35)
        forceTouchEnabled = value("forceTouchEnabled", true)
        hapticStrength = HapticStrength(rawValue: value("hapticStrength", "")) ?? .weak
        hoverPreview = value("hoverPreview", true)
        hoverToOpen = value("hoverToOpen", false)

        batteryChargerAlert = value("batteryChargerAlert", true)
        batteryFullAlert = value("batteryFullAlert", true)
        batteryLowAlert = value("batteryLowAlert", true)
        batteryLowThreshold = value("batteryLowThreshold", 20.0)

        netWifiPower = value("netWifiPower", true)
        netWifiConnection = value("netWifiConnection", true)
        netVPN = value("netVPN", true)
        netHotspot = value("netHotspot", true)
        netDuration = value("netDuration", 0.0)
        hotspotPinned = value("hotspotPinned", false)
        vpnPinned = value("vpnPinned", false)
        hotspotSSIDs = value("hotspotSSIDs", "")

        btEnabled = value("btEnabled", true)
        btStyle = AlertStyle(rawValue: value("btStyle", "")) ?? .compact
        btBattery = BatteryDisplay(rawValue: value("btBattery", "")) ?? .percent
        btShowDisconnect = value("btShowDisconnect", false)
        btBlocklist = value("btBlocklist", "")

        focusEnabled = value("focusEnabled", true)
        focusDuration = value("focusDuration", 0.0)
        focusPinned = value("focusPinned", false)
        focusExcluded = value("focusExcluded", "")

        hudVolume = value("hudVolume", true)
        hudDisplay = value("hudDisplay", true)
        hudKeyboard = value("hudKeyboard", true)
        hudStyle = HUDStyle(rawValue: value("hudStyle", "")) ?? .bar
        hudDuration = value("hudDuration", 1.5)
        hudOutputIcon = value("hudOutputIcon", true)
        hudDisplayExternal = value("hudDisplayExternal", true)
        hudKeyboardExternal = value("hudKeyboardExternal", true)

        netStyle = AlertStyle(rawValue: value("netStyle", "")) ?? .compact
        focusStyle = AlertStyle(rawValue: value("focusStyle", "")) ?? .compact
        batteryStyle = AlertStyle(rawValue: value("batteryStyle", "")) ?? .compact
        let savedOrder: [String] = value("persistentOrder", AppSettings.defaultPersistentOrder)
        // 새로 생긴 항목은 기본 순서대로 뒤에 붙인다.
        persistentOrder = (savedOrder.contains("call") ? [] : ["call"])   // 통화는 기존 사용자도 맨 위로
            + savedOrder.filter { AppSettings.defaultPersistentOrder.contains($0) }
            + AppSettings.defaultPersistentOrder.filter { !savedOrder.contains($0) && $0 != "call" }

        lockNotchEnabled = value("lockNotchEnabled", true)
        lockMediaWidget = value("lockMediaWidget", true)
        lockHideTrackInfo = value("lockHideTrackInfo", false)
        lockWidgetBottom = value("lockWidgetBottom", false)
        lyricsEnabled = value("lyricsEnabled", true)
        lyricsOnline = value("lyricsOnline", false)
        lyricsSize = value("lyricsSize", 1)
        aiUsagePinned = value("aiUsagePinned", false)
        aiUsageStyle = UsageStyle(rawValue: value("aiUsageStyle", "")) ?? .text
        aiUsageService = value("aiUsageService", "claude")
        chatEnabled = value("chatEnabled", false)
        chatWebSearch = value("chatWebSearch", true)
        chatInstructions = value(AppSettings.chatInstructionsKey, "")
        chatReopen = ChatReopen(rawValue: value("chatReopen", "")) ?? .lastAnswer
        chatService = ChatService(rawValue: value("chatService", "")) ?? .claude
        chatModelClaude = value("chatModelClaude", "")
        chatModelOpenAI = value("chatModelOpenAI", "")
        chatModelGemini = value("chatModelGemini", "")
        // 1·2·5·10분 중 하나 (예전 15~60분 값은 10분으로)
        aiRefreshMinutes = [1.0, 2.0, 5.0, 10.0].contains(value("aiRefreshMinutes", 5.0)) ? value("aiRefreshMinutes", 5.0) : 10
        aiConnected = value("aiConnected", "")
        agentAlerts = value("agentAlerts", true)
        agentStyle = AlertStyle(rawValue: value("agentStyle", "")) ?? .compact
        batteryChargingPinned = value("batteryChargingPinned", true)
        calendarPinned = value("calendarPinned", false)
        // 새로 생긴 홈 기능은 기본 순서대로 뒤에 붙인다
        let savedHome: [String] = value("homeOrder", AppSettings.defaultHomeOrder)
        homeOrder = savedHome.filter(AppSettings.defaultHomeOrder.contains) + AppSettings.defaultHomeOrder.filter { !savedHome.contains($0) }
        homeDisabled = value("homeDisabled", [String]())
        trayMode = TrayMode(rawValue: value("trayMode", "")) ?? .on

        mediaSource = MediaSource(rawValue: value("mediaSource", "")) ?? .all
        mediaHideAfterPause = value("mediaHideAfterPause", 30.0)
        mediaShowTrackChange = value("mediaShowTrackChange", true)
        mediaTrackChangeMusicOnly = value("mediaTrackChangeMusicOnly", true)

        downloadEnabled = value("downloadEnabled", true)
        downloadStyle = ProgressStyle(rawValue: value("downloadStyle", "")) ?? .ring
        downloadFolders = value("downloadFolders", "")
        downloadFolder = value("downloadFolder", AppSettings.defaultDownloadFolder)
        recordingFolder = value("recordingFolder", AppSettings.defaultRecordingFolder)

        trayKeepCopies = value("trayKeepCopies", false)
        trayCleanupDays = value("trayCleanupDays", 0.0)
        dragZoneHeight = value("dragZoneHeight", 120.0)
        fileDragPage = value("fileDragPage", "tray")
        airdropStyle = ProgressStyle(rawValue: value("airdropStyle", "")) ?? .ring

        screenshotEnabled = value("screenshotEnabled", true)
        screenshotSource = ScreenshotSource(rawValue: value("screenshotSource", "")) ?? .clipboard
        screenshotFolder = value("screenshotFolder", "")
        screenshotJPEG = value("screenshotJPEG", false)
        screenshotAutoClose = value("screenshotAutoClose", 10.0)

        recordingEnabled = value("recordingEnabled", true)
        callEnabled = value("callEnabled", true)
        recordingStyle = RecordingStyle(rawValue: value("recordingStyle", "")) ?? .persistent
        cameraMirror = value("cameraMirror", true)
        calendarAlertMinutes = value("calendarAlertMinutes", 10.0)
    }

    /// 설정 창은 별도 도우미 프로세스에서 열린다(창을 닫으면 프로세스째 메모리가 반환됨).
    /// 도우미가 값을 바꾸면 본 앱에 알려 다시 읽게 한다.
    static var isHelper = false
    static let changedNotification = Notification.Name("com.dynamicmacnotch.app.settingsChanged")
    private var loading = false

    private func save(_ value: Any, _ key: String) {
        guard !loading else { return }
        defaults.set(value, forKey: key)
        if Self.isHelper {
            DistributedNotificationCenter.default().postNotificationName(Self.changedNotification, object: key,
                                                                         userInfo: nil, deliverImmediately: true)
        }
    }
}
