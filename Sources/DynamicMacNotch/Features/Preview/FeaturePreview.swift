import AppKit
import SwiftUI

/// 설정 → 테스트에서 고를 수 있는 미리보기. 설정 창(도우미 프로세스)은 이 이름만 보낼 수 있다(허용 목록).
enum PreviewID: String, CaseIterable {
    // 네트워크
    case wifiOn = "wifi-on", wifiOff = "wifi-off", wifiConnected = "wifi-connected", wifiDisconnected = "wifi-disconnected"
    case vpnOn = "vpn-on", vpnOff = "vpn-off", hotspot, offline
    // 블루투스
    case btCompact = "bt-compact", btDetail = "bt-detail", btLow = "bt-low", btNoBattery = "bt-nobattery"
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
    // 모두 끝내기
    case stopAll = "stop-all"
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
    private let runBluetooth: (String) -> Void

    /// 예약해 둔 작업 (중지하면 모두 취소)
    private var work: [DispatchWorkItem] = []
    /// 미리보기가 띄운 상시 표시 종류 (중지하면 모두 내림)
    private var persistentKinds = Set<ActivityKind>()
    private var lockPreviewing = false

    init(center: ActivityCenter, battery: BatteryMonitor, media: MediaController, call: CallMonitor, focus: FocusMonitor,
         timer: TimerController, screenshot: ScreenshotMonitor, lockScreen: @escaping () -> LockScreenManager?,
         runBluetooth: @escaping (String) -> Void) {
        self.center = center
        self.battery = battery
        self.media = media
        self.call = call
        self.focus = focus
        self.timer = timer
        self.screenshot = screenshot
        self.lockScreen = lockScreen
        self.runBluetooth = runBluetooth
    }

    func run(_ id: PreviewID) {
        switch id {
        case .wifiOn: network("wifi", .blue, T("켜짐", "On"), "Wi-Fi", T("Wi-Fi 켜짐", "Wi-Fi On"))
        case .wifiOff: network("wifi.slash", .gray, T("꺼짐", "Off"), "Wi-Fi", T("Wi-Fi 꺼짐", "Wi-Fi Off"))
        case .wifiConnected: network("wifi", .blue, T("연결됨", "Connected"), "Wi-Fi", "Home_5G")
        case .wifiDisconnected: network("wifi.exclamationmark", .gray, T("해제됨", "Disconnected"), "Wi-Fi", T("연결 해제됨", "Disconnected"))
        case .vpnOn: network("lock.shield.fill", .green, T("연결됨", "Connected"), "VPN", "NordVPN")
        case .vpnOff: network("lock.open", .gray, T("해제됨", "Disconnected"), "VPN", T("연결 해제됨", "Disconnected"))
        case .hotspot:
            network("personalhotspot", .green, T("연결됨", "Connected"), T("개인용 핫스팟", "Personal Hotspot"), "iPhone")
        case .offline: DemoActivity.offline.run(center: center, battery: battery)
        case .btCompact: runBluetooth("bt-compact")
        case .btDetail: runBluetooth("bt-detail")
        case .btLow: DemoActivity.bluetoothLow.run(center: center, battery: battery)
        case .btNoBattery: DemoActivity.bluetoothNoBattery.run(center: center, battery: battery)
        case .focusOn: focus.debugPreview(on: true)
        case .focusOff: focus.debugPreview(on: false)
        case .hudVolume: DemoActivity.volume.run(center: center, battery: battery)
        case .hudBrightness: DemoActivity.brightness.run(center: center, battery: battery)
        case .hudKeyboard:
            center.post(NotchActivity(kind: .hud, priority: ActivityPriority.hud, duration: 1.5, symbol: "light.max",
                                      value: AppSettings.shared.hudStyle == .number ? .bigNumber(0.6) : .ring(0.6), wing: 56))
        case .charger:
            battery.postCharger(BatteryMonitor.read() ?? .init(percent: 64, isCharging: true, onAC: true, isCharged: false, minutesToFull: 48))
        case .low:
            battery.postLow(.init(percent: Int(AppSettings.shared.batteryLowThreshold), isCharging: false, onAC: false, isCharged: false))
        case .full: battery.postFull(.init(percent: 100, isCharging: false, onAC: true, isCharged: true))
        case .mediaStart: media.startTest()
        case .mediaStop: media.stopTest()
        case .download: download()
        case .airdropSend: airdropSend()
        case .airdropReceive:
            center.post(NotchActivity(kind: .airdrop, presentation: .detail, duration: 5, symbol: "airplayaudio", tint: .blue,
                                      value: .check, title: T("에어드랍 받음", "AirDrop Received"), subtitle: "Photo.heic"))
        case .screenshot: screenshot.presentPreview()
        case .recording:
            showPersistent(NotchActivity(kind: .demo, priority: ActivityPriority.recording, symbol: "record.circle", tint: .red,
                                         value: .recordingDot, title: T("화면 녹화", "Screen Recording"), wing: 44), for: 5)
        case .timerDone: timer.previewDone()
        case .calendar:
            center.post(NotchActivity(kind: .calendar, priority: ActivityPriority.info, presentation: .detail, duration: 6,
                                      symbol: "calendar", tint: .orange, value: .text(T("10분 후", "in 10 min")),
                                      title: T("팀 회의", "Team Meeting"), subtitle: T("오후 3:00 – 4:00", "3:00 – 4:00 PM")))
        case .callIncoming: call.startPreview(incoming: true)
        case .callActive: call.startPreview(incoming: false)
        case .lock: lockPreview()
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
        if let t = center.transient, t.kind != .lock { center.dismissTransient() }
        MemoryTrim.soon()
    }

    // MARK: - 각 미리보기

    private func network(_ symbol: String, _ tint: Color, _ short: String, _ title: String, _ detail: String) {
        let detailed = AppSettings.shared.netStyle == .detail
        center.post(NotchActivity(kind: .network, presentation: detailed ? .detail : .compact, symbol: symbol, tint: tint,
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
                    self.center.post(NotchActivity(kind: .download, priority: ActivityPriority.info, duration: 3,
                                                   symbol: "checkmark.circle.fill", tint: .green, value: .check,
                                                   title: T("다운로드 완료", "Download Complete"), subtitle: "Sample.zip", wing: 46))
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
