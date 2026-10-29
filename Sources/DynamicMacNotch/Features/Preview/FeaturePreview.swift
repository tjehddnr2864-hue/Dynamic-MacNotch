import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 설정 → 테스트에서 고를 수 있는 미리보기. 설정 창(도우미 프로세스)은 이 이름만 보낼 수 있다(허용 목록).
enum PreviewID: String, CaseIterable {
    // 네트워크
    case wifiOn = "wifi-on", wifiOff = "wifi-off", wifiConnected = "wifi-connected", wifiDisconnected = "wifi-disconnected"
    case vpnOn = "vpn-on", vpnOff = "vpn-off", hotspot, offline
    // 블루투스
    case airpods = "bt-airpods", btLow = "bt-low", btNoBattery = "bt-nobattery"
    // 집중 모드
    case focusOn = "focus-on", focusOff = "focus-off"
    // HUD
    case hudVolume = "hud-volume", hudBrightness = "hud-brightness", hudKeyboard = "hud-keyboard"
    // 배터리
    case charger, low, full
    // 활동
    case mediaStart = "media-start", mediaStop = "media-stop"
    case download, airdropSend = "airdrop-send", airdropReceive = "airdrop-receive"
    case screenshot, recording, timerDone = "timer-done", calendar
    // 전화
    case callIncoming = "call-incoming", callActive = "call-active"
    // 잠금화면
    case lock
    // AI 사용량
    case aiUsage = "ai-usage"
    // 코딩 에이전트
    case agentDone = "agent-done"
    // 모두 끝내기
    case stopAll = "stop-all"
}

/// 미리보기 알림의 표시 형태. 실제 기능과 똑같이 분류한다.
enum PreviewLayout {
    /// 설정의 '컴팩트/상세'를 따르는 알림 (테스트에서 골라 볼 수 있음)
    case selectable
    /// 항상 컴팩트 (노치 양옆)
    case compactOnly
    /// 항상 상세 카드
    case detailOnly
}

extension PreviewID {
    var layout: PreviewLayout {
        switch self {
        case .wifiOn, .wifiOff, .wifiConnected, .wifiDisconnected, .vpnOn, .vpnOff, .hotspot,
             .airpods, .btLow, .btNoBattery, .focusOn, .focusOff, .charger, .low, .full, .agentDone:
            return .selectable
        case .offline, .airdropReceive, .screenshot, .timerDone, .calendar, .callIncoming:
            return .detailOnly
        case .hudVolume, .hudBrightness, .hudKeyboard, .download, .airdropSend, .recording, .callActive, .lock, .aiUsage,
             .mediaStart, .mediaStop, .stopAll:
            return .compactOnly
        }
    }

    /// 노치 우클릭 메뉴 '알림 미리보기'에 넣는 대표 항목 (전체는 설정 → 테스트)
    static let menuItems: [PreviewID] = [.wifiConnected, .vpnOff, .airpods, .focusOn, .hudVolume, .charger, .low,
                                          .download, .recording, .callIncoming, .mediaStart]

    var menuTitle: String {
        switch self {
        case .wifiConnected: return T("Wi-Fi 연결", "Wi-Fi Connected")
        case .vpnOff: return T("VPN 해제", "VPN Disconnected")
        case .airpods: return T("AirPods 연결", "AirPods Connected")
        case .focusOn: return T("집중 모드 켜짐", "Focus On")
        case .hudVolume: return T("음량 HUD", "Volume HUD")
        case .charger: return T("충전기 연결", "Charger Connected")
        case .low: return T("배터리 부족", "Low Battery")
        case .download: return T("다운로드", "Download")
        case .recording: return T("화면 녹화", "Screen Recording")
        case .callIncoming: return T("수신 전화", "Incoming Call")
        case .mediaStart: return T("음악 재생 테스트", "Music Playback Test")
        default: return rawValue
        }
    }
}

/// 미리보기 실행기. 미리보기가 만든 것(예약 작업, 상시 표시, 가짜 음악·통화·잠금·스크린샷)을 모두 기록해 두고,
/// 끝나거나 '모든 미리보기 중지'를 누르면 남김없이 거둔다 (타이머·참조가 남아 메모리·CPU를 쓰지 않게).
final class FeaturePreview {
    private let center: ActivityCenter
    private let battery: BatteryMonitor
    private let media: MediaController
    private let call: CallMonitor
    private let focus: FocusMonitor
    private let timer: TimerController
    private let screenshot: ScreenshotMonitor
    private let lockScreen: () -> LockScreenManager?

    /// 예약해 둔 작업 (중지하면 모두 취소)
    private var work: [DispatchWorkItem] = []
    /// 미리보기가 띄운 상시 표시 종류 (중지하면 모두 내림)
    private var persistentKinds = Set<ActivityKind>()
    private var lockPreviewing = false
    /// 테스트에서 고른 표시 형태 (nil이면 실제 설정을 따른다). 실행하는 동안만 쓴다.
    private var style: AlertStyle?

    init(center: ActivityCenter, battery: BatteryMonitor, media: MediaController, call: CallMonitor, focus: FocusMonitor,
         timer: TimerController, screenshot: ScreenshotMonitor, lockScreen: @escaping () -> LockScreenManager?) {
        self.center = center
        self.battery = battery
        self.media = media
        self.call = call
        self.focus = focus
        self.timer = timer
        self.screenshot = screenshot
        self.lockScreen = lockScreen
    }

    /// `style`은 컴팩트·상세를 고를 수 있는 알림에만 적용된다.
    func run(_ id: PreviewID, style: AlertStyle? = nil) {
        self.style = id.layout == .selectable ? style : nil
        defer { self.style = nil }
        switch id {
        case .wifiOn: network("wifi", .blue, T("켜짐", "On"), "Wi-Fi", T("Wi-Fi 켜짐", "Wi-Fi On"))
        case .wifiOff: network("wifi.slash", .gray, T("꺼짐", "Off"), "Wi-Fi", T("Wi-Fi 꺼짐", "Wi-Fi Off"))
        case .wifiConnected: network("wifi", .blue, T("연결됨", "Connected"), "Wi-Fi", "Home_5G")
        case .wifiDisconnected: network("wifi.exclamationmark", .gray, T("해제됨", "Disconnected"), "Wi-Fi", T("연결 해제됨", "Disconnected"))
        case .vpnOn: network("lock.shield.fill", .green, T("연결됨", "Connected"), "VPN", "NordVPN")
        case .vpnOff: network("lock.open", .gray, T("해제됨", "Disconnected"), "VPN", T("연결 해제됨", "Disconnected"))
        case .hotspot:
            network("personalhotspot", .green, T("연결됨", "Connected"), T("개인용 핫스팟", "Personal Hotspot"), "iPhone")
        case .offline:
            center.post(NotchActivity(kind: .network, presentation: .detail, duration: 4, symbol: "antenna.radiowaves.left.and.right.slash",
                                      tint: .orange, value: .text(T("없음", "None")), title: T("연결된 네트워크 없음", "No Network Connection"),
                                      subtitle: T("Wi-Fi·셀룰러 연결이 끊겼습니다", "Wi-Fi and cellular are disconnected")))
        case .airpods:
            let s = AppSettings.shared
            let value: ActivityValue = switch s.btBattery {
            case .percent: .percent(0.82)
            case .ring: .ring(0.82)
            case .both: .ringPercent(0.82)
            }
            center.post(NotchActivity(kind: .bluetooth, presentation: presentation(s.btStyle), symbol: "airpodspro", tint: .green,
                                      value: value, title: "AirPods Pro",
                                      subtitle: T("왼쪽 82% · 오른쪽 84% · 케이스 60%", "Left 82% · Right 84% · Case 60%"),
                                      detailValue: value, wing: s.btBattery == .both ? 70 : 56, valueTint: .green))
        case .btLow:
            center.post(NotchActivity(kind: .bluetooth, presentation: presentation(AppSettings.shared.btStyle), symbol: "computermouse",
                                      tint: .red, value: .percent(0.12), title: "Magic Mouse", subtitle: T("연결됨", "Connected"),
                                      detailValue: .percent(0.12), wing: 56, valueTint: .red))
        case .btNoBattery:
            let text = T("연결됨", "Connected")
            center.post(NotchActivity(kind: .bluetooth, presentation: presentation(AppSettings.shared.btStyle), symbol: "gamecontroller.fill",
                                      tint: .green, value: .text(text), title: T("게임 컨트롤러", "Game Controller"), subtitle: text,
                                      wing: NetworkMonitor.wing(for: text), valueTint: .white))
        case .focusOn: focus.preview(on: true, style: style)
        case .focusOff: focus.preview(on: false, style: style)
        case .hudVolume:
            // 연속으로 조절할 때처럼 값만 바뀌는지 보여 준다
            for (i, v) in [0.40, 0.46, 0.53, 0.60].enumerated() {
                schedule(after: Double(i) * 0.25) { [weak self] in
                    self?.center.post(NotchActivity(kind: .hud, priority: ActivityPriority.hud, duration: 1.5, symbol: "speaker.wave.2.fill",
                                                    value: Self.hudValue(v), wing: AppSettings.shared.hudStyle == .bar ? 66 : 54))
                }
            }
        case .hudBrightness:
            center.post(NotchActivity(kind: .hud, priority: ActivityPriority.hud, duration: 1.5, symbol: "sun.max.fill", tint: .yellow,
                                      value: Self.hudValue(0.7), wing: AppSettings.shared.hudStyle == .bar ? 66 : 54))
        case .hudKeyboard:
            center.post(NotchActivity(kind: .hud, priority: ActivityPriority.hud, duration: 1.5, symbol: "light.max",
                                      value: Self.hudValue(0.6), wing: AppSettings.shared.hudStyle == .bar ? 66 : 54))
        case .charger:
            battery.postCharger(BatteryMonitor.read() ?? .init(percent: 64, isCharging: true, onAC: true, isCharged: false, minutesToFull: 48),
                                style: style)
        case .low:
            battery.postLow(.init(percent: Int(AppSettings.shared.batteryLowThreshold), isCharging: false, onAC: false, isCharged: false),
                            style: style)
        case .full: battery.postFull(.init(percent: 100, isCharging: false, onAC: true, isCharged: true), style: style)
        case .mediaStart: media.startTest()
        case .mediaStop: media.stopTest()
        case .download: download()
        case .airdropSend: airdropSend()
        case .airdropReceive:
            center.post(NotchActivity(kind: .airdrop, presentation: .detail, duration: 5, symbol: "airplayaudio", tint: .blue,
                                      value: .check, title: T("에어드랍 받음", "AirDrop Received"), subtitle: "Photo.heic"))
        case .screenshot: screenshot.presentPreview()
        case .recording:
            if AppSettings.shared.recordingStyle == .persistent {
                showPersistent(NotchActivity(kind: .demo, priority: ActivityPriority.recording, symbol: "record.circle.fill", tint: .red,
                                             value: .elapsed(Date()), title: T("화면 녹화", "Screen Recording"),
                                             wing: NotchActivity.compactWing), for: 6)
            } else {
                center.post(NotchActivity(kind: .demo, duration: 3, symbol: "record.circle.fill", tint: .red,
                                          value: .text(T("녹화 시작", "Recording")), title: T("화면 녹화", "Screen Recording"),
                                          wing: NetworkMonitor.wing(for: T("녹화 시작", "Recording"))))
            }
        case .timerDone: timer.previewDone()
        case .calendar:
            center.post(NotchActivity(kind: .calendar, priority: ActivityPriority.info, presentation: .detail, duration: 6,
                                      symbol: "calendar", tint: .orange, value: .text(T("10분 후", "in 10 min")),
                                      title: T("팀 회의", "Team Meeting"), subtitle: T("오후 3:00 – 4:00", "3:00 – 4:00 PM")))
        case .callIncoming: call.startPreview(incoming: true)
        case .callActive: call.startPreview(incoming: false)
        case .lock: lockPreview()
        case .agentDone:
            center.post(AgentNotify.activity(.claude, project: "DynamicMacNotch", task: T("메모 기능 UI 수정", "Tweak the memo UI"),
                                             target: nil, style: style ?? AppSettings.shared.agentStyle))
        case .aiUsage:
            // 상시 표시 모양 (설정의 텍스트·원형을 따름) 6초
            let service = AIService(rawValue: AppSettings.shared.aiUsageService) ?? .claude
            let sample = ServiceUsage(windows: [
                UsageWindow(percent: 42, resetsAt: Date().addingTimeInterval(2 * 3600), seconds: UsageWindow.fiveHours),
                UsageWindow(percent: 76, resetsAt: Date().addingTimeInterval(3 * 86400), seconds: UsageWindow.week)
            ], fetched: Date())
            var a = UsageStore.activity(service: service, usage: sample, ring: AppSettings.shared.aiUsageStyle == .ring)
            a.kind = .demo
            showPersistent(a, for: 6)
        case .stopAll: stopAll()
        }
    }

    /// 미리보기가 만든 모든 것을 거둔다.
    func stopAll() {
        work.forEach { $0.cancel() }
        work.removeAll()
        for kind in persistentKinds { center.removePersistent(kind) }
        persistentKinds.removeAll()
        media.stopTest()
        call.stopPreview()
        screenshot.endPreview()
        if lockPreviewing, let lock = lockScreen() {
            lockPreviewing = false
            lock.unlock()
        }
        // 대기열을 먼저 비워야 지금 알림을 닫았을 때 뒤에 쌓인 미리보기가 이어서 뜨지 않는다
        center.clearPending()
        if let t = center.transient, t.kind != .lock { center.dismissTransient() }
        MemoryGuard.shared.checkSoon()
    }

    // MARK: - 각 미리보기

    /// HUD 수치 표시 방식(숫자·바·원형)에 맞춘 값
    private static func hudValue(_ v: Double) -> ActivityValue {
        switch AppSettings.shared.hudStyle {
        case .number: return .bigNumber(v)
        case .bar: return .bar(v)
        case .ring: return .ring(v)
        }
    }

    /// 테스트에서 고른 형태, 없으면 실제 설정
    private func presentation(_ setting: AlertStyle) -> ActivityPresentation {
        (style ?? setting) == .detail ? .detail : .compact
    }

    private func network(_ symbol: String, _ tint: Color, _ short: String, _ title: String, _ detail: String) {
        center.post(NotchActivity(kind: .network, presentation: presentation(AppSettings.shared.netStyle), symbol: symbol, tint: tint,
                                  value: .text(short), title: title, subtitle: detail, wing: NetworkMonitor.wing(for: short)))
    }

    /// 다운로드: 4초 동안 0 → 100% 진행 후 완료 알림
    private func download() {
        let steps = 8
        for i in 0...steps {
            schedule(after: Double(i) * 0.5) { [weak self] in
                guard let self else { return }
                let f = Double(i) / Double(steps)
                if i < steps {
                    self.showPersistent(NotchActivity(kind: .download, priority: ActivityPriority.download, symbol: "arrow.down.circle.fill",
                                                      tint: .blue, value: .ring(f), title: "Sample.zip",
                                                      subtitle: "\(Int(f * 100))%", detailValue: .ringPercent(f)))
                } else {
                    self.hidePersistent(.download)
                    // 실제 완료 알림과 같은 구성 (파일 아이콘 · Finder에서 보기). 가짜 파일이므로 Finder는 폴더를 연다.
                    let folder = AppSettings.folderURL(AppSettings.shared.downloadFolder, fallback: AppSettings.defaultDownloadFolder)
                    self.center.post(NotchActivity(kind: .download, priority: ActivityPriority.info, duration: 3,
                                                   symbol: "checkmark.circle.fill", tint: .green, value: .check,
                                                   title: T("다운로드 완료", "Download Complete"), subtitle: "Sample.zip", wing: 46,
                                                   artwork: NSWorkspace.shared.icon(for: .zip),
                                                   fileURL: folder.appendingPathComponent("Sample.zip")))
                }
            }
        }
    }

    /// 에어드랍 보내기: 진행 후 '전송 완료'
    private func airdropSend() {
        for (i, f) in [0.0, 0.3, 0.65, 1.0].enumerated() {
            schedule(after: Double(i) * 0.8) { [weak self] in
                guard let self else { return }
                if f < 1 {
                    self.showPersistent(NotchActivity(kind: .airdrop, priority: ActivityPriority.download + 1, symbol: "airplayaudio",
                                                      tint: .blue, value: f == 0 ? .spinner : .ring(f), title: T("에어드랍", "AirDrop"),
                                                      subtitle: "Photo.heic", wing: 50))
                } else {
                    self.hidePersistent(.airdrop)
                    let message = T("전송 완료", "Sent")
                    self.center.post(NotchActivity(kind: .airdrop, symbol: "checkmark.circle.fill", tint: .green, value: .text(message),
                                                   title: T("에어드랍", "AirDrop"), wing: NetworkMonitor.wing(for: message)))
                }
            }
        }
    }

    /// 잠금화면: 실제로 잠그지 않고 자물쇠·위젯을 5초 보여 준 뒤 풀림 애니메이션
    private func lockPreview() {
        guard let lock = lockScreen(), !lock.isLocked else { return }
        lockPreviewing = true
        lock.lock(preview: true)
        schedule(after: 5) { [weak self] in
            guard let self, self.lockPreviewing else { return }
            self.lockPreviewing = false
            self.lockScreen()?.unlock()
        }
    }

    // MARK: - 정리 가능한 도우미

    private func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        let item = DispatchWorkItem(block: block)
        work.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            if !item.isCancelled { item.perform() }
            self?.work.removeAll { $0 === item }   // 실행한 작업은 목록에서 뺀다 (목록이 쌓이지 않게)
        }
    }

    private func showPersistent(_ activity: NotchActivity, for seconds: TimeInterval? = nil) {
        persistentKinds.insert(activity.kind)
        center.setPersistent(activity)
        if let seconds {
            schedule(after: seconds) { [weak self] in self?.hidePersistent(activity.kind) }
        }
    }

    private func hidePersistent(_ kind: ActivityKind) {
        persistentKinds.remove(kind)
        center.removePersistent(kind)
    }
}
