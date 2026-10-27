import SwiftUI

/// 설정 창 (가이드라인 7장 중 1차 빌드 범위). 값은 바뀌는 즉시 노치에 반영된다.
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var hud: HUDStatus
    var openPermissions: () -> Void
    var preview: (String) -> Void

    var body: some View {
        TabView {
            general.tabItem { Label(T("일반", "General"), systemImage: "gearshape") }
            interaction.tabItem { Label(T("상호작용", "Interaction"), systemImage: "hand.tap") }
            network.tabItem { Label(T("네트워크", "Network"), systemImage: "wifi") }
            bluetoothAndFocus.tabItem { Label(T("블루투스·집중", "Bluetooth & Focus"), systemImage: "airpodspro") }
            activities.tabItem { Label(T("활동", "Activities"), systemImage: "music.note") }
            battery.tabItem { Label(T("배터리", "Battery"), systemImage: "battery.75percent") }
            hudTab.tabItem { Label("HUD", systemImage: "speaker.wave.2") }
            lockTab.tabItem { Label(T("잠금화면", "Lock Screen"), systemImage: "lock") }
            testTab.tabItem { Label(T("테스트", "Test"), systemImage: "play.rectangle") }
            about.tabItem { Label(T("정보", "About"), systemImage: "info.circle") }
        }
        .frame(width: 700, height: 560)
    }

    /// 이 설정 창이 열릴 때의 언어 (바뀌었는지 비교용)
    private static let launchLanguage = AppSettings.shared.language

    private var general: some View {
        Form {
            Picker(T("언어", "Language"), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
            }
            if settings.language != Self.launchLanguage {
                HStack {
                    Text(T("다시 시작하면 적용됩니다.", "Applies after restarting the app."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(T("지금 다시 시작", "Restart Now")) {
                        Helper.sendToMain("restart")
                        NSApp.terminate(nil)   // 설정 창(도우미)도 닫는다
                    }
                }
            }
            Picker(T("표시 화면", "Display"), selection: $settings.displayTarget) {
                ForEach(DisplayTarget.allCases) { Text($0.label).tag($0) }
            }
            Picker(T("일회성 알림 표시 시간", "Alert Duration"), selection: $settings.transientDuration) {
                ForEach([1.5, 2.5, 4.0, 6.0], id: \.self) { Text(L10n.seconds($0, digits: 1)).tag($0) }
            }
            Toggle(T("메뉴바 아이콘 표시", "Show Menu Bar Icon"), isOn: $settings.showStatusItem)
            Toggle(T("자동 업데이트 (하루 한 번 확인)", "Automatic updates (checks daily)"), isOn: $settings.autoUpdate)
            Toggle(T("메모리 자동 최적화 (기준을 넘으면 쉬는 동안 조용히 다시 시작)", "Automatic memory cleanup (quietly restarts while idle above the limit)"), isOn: $settings.memoryGuard)
            Picker(T("최적화 기준", "Cleanup Limit"), selection: $settings.memoryLimitMB) {
                ForEach([70.0, 80.0, 90.0, 100.0, 110.0, 120.0, 130.0, 140.0, 150.0], id: \.self) { Text("\(Int($0)) MB").tag($0) }
            }
            .disabled(!settings.memoryGuard)
            Button(T("권한 관리 열기…", "Open Permissions…"), action: openPermissions)

            Section {
                ForEach(Array(settings.persistentOrder.enumerated()), id: \.element) { index, key in
                    HStack {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
                        Label(Self.persistentName(key), systemImage: Self.persistentSymbol(key))
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == settings.persistentOrder.count - 1)
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text(T("상시 표시 우선순위", "Live Activity Priority"))
            } footer: {
                Text(T("여러 항목이 동시에 진행 중이면 위에 있는 항목이 노치에 표시됩니다. 노치 위에서 두 손가락으로 위로 쓸면 숨기고, 아래로 쓸면 다시 나타납니다.", "When several activities run at once, the one higher in the list is shown. Swipe up with two fingers on the notch to hide them, and swipe down to show them again."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func move(_ index: Int, by delta: Int) {
        var order = settings.persistentOrder
        let target = index + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        withAnimation { settings.persistentOrder = order }
    }

    static func persistentName(_ key: String) -> String {
        switch key {
        case "call": return T("통화", "Phone Call")
        case "recording": return T("화면 녹화", "Screen Recording")
        case "timer": return T("타이머", "Timer")
        case "airdrop": return T("에어드랍 전송", "AirDrop Transfer")
        case "download": return T("다운로드", "Download")
        case "media": return T("음악 재생", "Music")
        case "hotspot": return T("핫스팟 연결", "Hotspot")
        case "focusPinned": return T("집중 모드", "Focus")
        default: return key
        }
    }

    static func persistentSymbol(_ key: String) -> String {
        switch key {
        case "call": return "phone.fill"
        case "recording": return "record.circle"
        case "timer": return "timer"
        case "airdrop": return "airplayaudio"
        case "download": return "arrow.down.circle"
        case "media": return "music.note"
        case "hotspot": return "personalhotspot"
        case "focusPinned": return "moon"
        default: return "circle"
        }
    }

    private var interaction: some View {
        Form {
            Section {
                LabeledContent(T("길게누르기 시간", "Long-Press Duration")) {
                    HStack {
                        Slider(value: $settings.longPressDuration, in: 0.2...0.8, step: 0.05)
                        Text(L10n.seconds(settings.longPressDuration, digits: 2)).monospacedDigit().frame(width: 52)
                    }
                }
                Toggle(T("깊게누르기(포스터치)로 바로 열기", "Open with Force Click"), isOn: $settings.forceTouchEnabled)
                Picker(T("햅틱 강도", "Haptic Strength"), selection: $settings.hapticStrength) {
                    ForEach(HapticStrength.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(T("마우스는 압력 이벤트가 없어 길게누르기만 동작합니다.", "Mice don't report pressure, so only long-press works with a mouse.")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(T("호버 시 살짝 커지는 미리보기", "Grow slightly on hover"), isOn: $settings.hoverPreview)
                Toggle(T("호버만으로 열기", "Open on hover"), isOn: $settings.hoverToOpen)
            }
        }
        .formStyle(.grouped)
    }

    private var durationPicker: some View {
        Picker(T("표시 시간", "Duration"), selection: $settings.netDuration) {
            Text(T("일반 설정 따름", "Use General Setting")).tag(0.0)
            ForEach([1.5, 2.5, 4.0, 6.0], id: \.self) { Text(L10n.seconds($0, digits: 1)).tag($0) }
        }
    }

    private var network: some View {
        Form {
            Section(T("표시할 이벤트", "Events to Show")) {
                Toggle(T("Wi-Fi 켜짐 / 꺼짐", "Wi-Fi On / Off"), isOn: $settings.netWifiPower)
                Toggle(T("Wi-Fi 연결됨 / 연결 해제됨", "Wi-Fi Connected / Disconnected"), isOn: $settings.netWifiConnection)
                Toggle(T("VPN 연결됨 / 연결 해제됨", "VPN Connected / Disconnected"), isOn: $settings.netVPN)
                Toggle(T("핫스팟 연결됨 / 연결 해제됨", "Hotspot Connected / Disconnected"), isOn: $settings.netHotspot)
                Picker(T("표시 방식", "Style"), selection: $settings.netStyle) {
                    ForEach(AlertStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                durationPicker
            }
            Section {
                Toggle(T("핫스팟 연결 중 상시 표시", "Keep showing while on a hotspot"), isOn: $settings.hotspotPinned)
                TextField(T("핫스팟으로 볼 Wi-Fi 이름(쉼표 구분)", "Wi-Fi names to treat as hotspots (comma-separated)"), text: $settings.hotspotSSIDs)
            } header: {
                Text(T("핫스팟", "Hotspot"))
            } footer: {
                Text(T("핫스팟은 '데이터 절약 네트워크' 여부로 추정합니다. 잘 안 잡히면 iPhone의 Wi-Fi 이름을 적어 주세요. Wi-Fi 이름 표시에는 위치 서비스 권한이 필요합니다.", "Hotspots are detected from the 'Low Data Mode' network flag. If yours isn't detected, enter your iPhone's Wi-Fi name. Showing Wi-Fi names requires Location Services permission."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var bluetoothAndFocus: some View {
        Form {
            Section(T("블루투스 액세서리", "Bluetooth Accessories")) {
                Toggle(T("연결 시 표시", "Show on connect"), isOn: $settings.btEnabled)
                Picker(T("표시 모드", "Style"), selection: $settings.btStyle) {
                    ForEach(AlertStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(T("배터리 표시", "Battery Display"), selection: $settings.btBattery) {
                    ForEach(BatteryDisplay.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField(T("알림 끌 기기 이름(쉼표 구분)", "Devices to ignore (comma-separated)"), text: $settings.btBlocklist)
                HStack {
                    Button(T("컴팩트 미리보기", "Preview Compact")) { preview("bt-airpods@compact") }
                    Button(T("상세 미리보기", "Preview Detailed")) { preview("bt-airpods@detail") }
                }
            }
            Section {
                Toggle(T("켜짐 / 꺼짐 표시", "Show On / Off"), isOn: $settings.focusEnabled)
                Picker(T("표시 방식", "Style"), selection: $settings.focusStyle) {
                    ForEach(AlertStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(T("표시 시간", "Duration"), selection: $settings.focusDuration) {
                    Text(T("일반 설정 따름", "Use General Setting")).tag(0.0)
                    ForEach([1.5, 2.5, 4.0, 6.0], id: \.self) { Text(L10n.seconds($0, digits: 1)).tag($0) }
                }
                Toggle(T("집중 모드 켜진 동안 상시 표시", "Keep showing while Focus is on"), isOn: $settings.focusPinned)
                TextField(T("표시하지 않을 모드 이름(쉼표 구분)", "Modes to ignore (comma-separated)"), text: $settings.focusExcluded)
            } header: {
                Text(T("집중 모드", "Focus"))
            } footer: {
                Text(T("모드 이름·아이콘은 전체 디스크 접근 권한이 있을 때만 표시됩니다. 없으면 '집중 모드 켬/끔'으로 표시합니다.", "Mode names and icons require Full Disk Access. Without it, alerts just say 'Focus On/Off'."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var hudTab: some View {
        Form {
            Section {
                LabeledContent(T("상태", "Status")) {
                    Text(hud.active ? T("동작 중", "Active") : T("손쉬운 사용 권한 필요", "Accessibility permission needed"))
                        .foregroundStyle(hud.active ? .green : .orange)
                }
                if !hud.active {
                    Button(T("권한 관리 열기…", "Open Permissions…"), action: openPermissions)
                }
            }
            Section(T("대체할 HUD", "HUDs to Replace")) {
                Toggle(T("음량", "Volume"), isOn: $settings.hudVolume)
                Toggle(T("화면 밝기", "Display Brightness"), isOn: $settings.hudDisplay)
                Toggle(T("키보드 밝기", "Keyboard Brightness"), isOn: $settings.hudKeyboard)
            }
            Section(T("표시", "Display")) {
                Picker(T("수치 표시", "Value Style"), selection: $settings.hudStyle) {
                    ForEach(HUDStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(T("표시 시간", "Duration"), selection: $settings.hudDuration) {
                    ForEach([1.0, 1.5, 2.5, 4.0], id: \.self) { Text(L10n.seconds($0, digits: 1)).tag($0) }
                }
                Toggle(T("음량 HUD에 출력 기기 아이콘 표시", "Show output device icon in volume HUD"), isOn: $settings.hudOutputIcon)
                Toggle(T("제어 센터에서 직접 바꾼 화면 밝기도 표시", "Also show display brightness changed in Control Center"), isOn: $settings.hudDisplayExternal)
                Toggle(T("제어 센터에서 직접 바꾼 키보드 밝기도 표시", "Also show keyboard brightness changed in Control Center"), isOn: $settings.hudKeyboardExternal)
            }
        }
        .formStyle(.grouped)
    }

    private var activities: some View {
        Form {
            Section(T("미디어", "Media")) {
                Picker(T("재생 소스", "Source"), selection: $settings.mediaSource) {
                    ForEach(MediaSource.allCases) { Text($0.label).tag($0) }
                }
                Picker(T("일시정지 후 숨김", "Hide After Pause"), selection: $settings.mediaHideAfterPause) {
                    Text(T("숨기지 않음", "Never")).tag(0.0)
                    ForEach([10.0, 30.0, 60.0], id: \.self) { Text(T("\(Int($0))초", "\(Int($0))s")).tag($0) }
                }
                Toggle(T("곡이 바뀌면 잠깐 크게 표시", "Briefly show the new song"), isOn: $settings.mediaShowTrackChange)
                Toggle(T("Apple Music·Spotify에서만", "Only for Apple Music and Spotify"), isOn: $settings.mediaTrackChangeMusicOnly)
                    .padding(.leading, 16)
                    .disabled(!settings.mediaShowTrackChange)
            }
            Section(T("다운로드", "Download")) {
                Toggle(T("다운로드 진행 표시", "Show download progress"), isOn: $settings.downloadEnabled)
                Picker(T("진행률", "Progress"), selection: $settings.downloadStyle) {
                    ForEach(ProgressStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                FolderSetting(title: T("바로가기 경로", "Shortcut Folder"), path: $settings.downloadFolder,
                              defaultPath: AppSettings.defaultDownloadFolder)
                TextField(T("추가 감시 폴더(쉼표 구분 경로)", "Extra folders to watch (comma-separated paths)"), text: $settings.downloadFolders)
            }
            Section {
                Picker(T("에어드랍 진행률", "AirDrop Progress"), selection: $settings.airdropStyle) {
                    ForEach(ProgressStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(T("트레이에 복사본 보관(원본이 옮겨져도 유지)", "Keep copies in the tray (survive moves)"), isOn: $settings.trayKeepCopies)
                Picker(T("트레이 자동 정리", "Auto-Clean Tray"), selection: $settings.trayCleanupDays) {
                    Text(T("끄기", "Off")).tag(0.0)
                    Text(T("1일", "1 day")).tag(1.0)
                    Text(T("7일", "7 days")).tag(7.0)
                }
                LabeledContent(T("드래그 감지 높이", "Drag Detection Height")) {
                    HStack {
                        Slider(value: $settings.dragZoneHeight, in: 60...200, step: 10)
                        Text("\(Int(settings.dragZoneHeight))pt").monospacedDigit().frame(width: 44)
                    }
                }
            } header: {
                Text(T("파일 트레이 · 에어드랍", "File Tray · AirDrop"))
            } footer: {
                Text(T("파일을 들고 화면 위쪽 감지 높이 안으로 오면, 가장자리에 닿기 전에 노치가 먼저 열려 미션 컨트롤이 뜨지 않게 합니다.", "When you drag a file into this zone at the top of the screen, the notch opens before you reach the edge, so Mission Control doesn't trigger."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(T("스크린샷", "Screenshot")) {
                Toggle(T("스크린샷 미리보기", "Screenshot preview"), isOn: $settings.screenshotEnabled)
                Picker(T("감지 대상", "Detect"), selection: $settings.screenshotSource) {
                    ForEach(ScreenshotSource.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField(T("저장 폴더(비우면 데스크탑)", "Save folder (empty = Desktop)"), text: $settings.screenshotFolder)
                Toggle(T("JPEG로 저장", "Save as JPEG"), isOn: $settings.screenshotJPEG)
                Picker(T("자동 닫힘", "Auto-Close"), selection: $settings.screenshotAutoClose) {
                    ForEach([5.0, 10.0, 30.0], id: \.self) { Text(T("\(Int($0))초", "\(Int($0))s")).tag($0) }
                }
            }
            Section(T("기타", "Other")) {
                Toggle(T("화면 녹화 표시", "Show screen recording"), isOn: $settings.recordingEnabled)
                Picker(T("화면 녹화 표시 방식", "Screen Recording Display"), selection: $settings.recordingStyle) {
                    ForEach(RecordingStyle.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.recordingEnabled)
                FolderSetting(title: T("바로가기 경로", "Shortcut Folder"), path: $settings.recordingFolder,
                              defaultPath: AppSettings.defaultRecordingFolder)
                    .disabled(!settings.recordingEnabled)
                Toggle(T("전화 수신·통화 표시 (iPhone 연속성·FaceTime 오디오)", "Show incoming and active calls (iPhone Continuity, FaceTime audio)"), isOn: $settings.callEnabled)
                Toggle(T("카메라 좌우 반전(거울)", "Mirror camera"), isOn: $settings.cameraMirror)
                Picker(T("일정 알림", "Event Alerts"), selection: $settings.calendarAlertMinutes) {
                    Text(T("끄기", "Off")).tag(0.0)
                    ForEach([5.0, 10.0, 15.0], id: \.self) { Text(T("\(Int($0))분 전", "\(Int($0)) min before")).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var lockTab: some View {
        Form {
            Section(T("노치", "Notch")) {
                Toggle(T("잠기면 자물쇠 표시, 풀리면 열림 애니메이션", "Show a lock when locked and an unlock animation"), isOn: $settings.lockNotchEnabled)
            }
            Section {
                Toggle(T("음악 재생 중 잠금화면 미디어 위젯", "Lock screen media widget while playing"), isOn: $settings.lockMediaWidget)
                Toggle(T("잠금화면에서 곡 정보 숨기기", "Hide song info on the lock screen"), isOn: $settings.lockHideTrackInfo)
            } header: {
                Text(T("미디어 위젯", "Media Widget"))
            } footer: {
                Text(T("위젯은 프로필 사진·암호 입력란 바로 위에 표시됩니다. 앨범아트를 누르면 전체화면 플레이어로 커집니다. 잠금화면에 창을 띄우는 기능은 비공개 API를 쓰므로 macOS 업데이트에 따라 동작하지 않을 수 있습니다.", "The widget appears just above your profile picture and password field. Click the album art for a full-screen player. Showing windows on the lock screen uses private APIs and may stop working after a macOS update."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(T("전체화면에서 가사 표시", "Show lyrics in full screen"), isOn: $settings.lyricsEnabled)
                Toggle(T("실시간(시간 동기) 가사 가져오기", "Fetch live (time-synced) lyrics"), isOn: $settings.lyricsOnline)
                Picker(T("가사 글자 크기", "Lyrics Size"), selection: $settings.lyricsSize) {
                    Text(T("작게", "Small")).tag(0)
                    Text(T("보통", "Medium")).tag(1)
                    Text(T("크게", "Large")).tag(2)
                }
                .pickerStyle(.segmented)
            } header: {
                Text(T("가사 (Apple Music)", "Lyrics (Apple Music)"))
            } footer: {
                Text(T("실시간 가사는 곡 제목·아티스트·앨범을 외부 가사 서비스 LRCLIB(lrclib.net)로 보내 받아옵니다. 끄면 Music 앱에 저장된 가사만 표시합니다.", "Live lyrics send the song title, artist and album to LRCLIB (lrclib.net). When off, only lyrics stored in the Music app are shown."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var battery: some View {
        Form {
            Section {
                Toggle(T("충전기 연결 알림", "Charger connected alert"), isOn: $settings.batteryChargerAlert)
                Toggle(T("완충 알림", "Fully charged alert"), isOn: $settings.batteryFullAlert)
                Toggle(T("배터리 부족 경고", "Low battery warning"), isOn: $settings.batteryLowAlert)
                LabeledContent(T("경고 기준", "Warning Level")) {
                    HStack {
                        Slider(value: $settings.batteryLowThreshold, in: 5...50, step: 5)
                        Text("\(Int(settings.batteryLowThreshold))%").monospacedDigit().frame(width: 40)
                    }
                }
                Picker(T("알림 표시 방식", "Alert Style"), selection: $settings.batteryStyle) {
                    ForEach(AlertStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section(T("미리보기", "Preview")) {
                HStack {
                    Button(T("충전기 연결", "Charger Connected")) { preview("charger") }
                    Button(T("배터리 부족", "Low Battery")) { preview("low") }
                    Button(T("완충", "Full")) { preview("full") }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 테스트 (기능별 미리보기)

    private var testTab: some View {
        Form {
            Section {
                HStack {
                    Text(T("각 버튼을 누르면 노치에 해당 기능이 미리 표시됩니다. 실제 설정·파일·통화에는 영향이 없습니다.",
                           "Each button previews that feature in the notch. Your real settings, files and calls are not affected."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(T("모든 미리보기 중지", "Stop All Previews")) { preview("stop-all") }
                }
            }
            Section(T("음악", "Music")) {
                HStack {
                    Button(T("재생 테스트 시작", "Start Playback Test")) { preview("media-start") }
                    Button(T("테스트 중지", "Stop Test")) { preview("media-stop") }
                }
                Text(T("테스트 곡이 노치에 재생됩니다. 길게 눌러 플레이어를 열고 재생·다음·이전·재생 바를 시험해 보세요. 30초 동안 조작이 없으면 자동으로 중지됩니다.",
                       "A test song plays in the notch. Long-press to open the player and try play, next, previous and the progress bar. It stops automatically after 30 seconds without interaction."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            // 컴팩트·상세를 고를 수 있는 알림: 묶음마다 형태를 골라 미리 본다 (실제 설정은 바뀌지 않음)
            StylePreviewSection(title: T("네트워크", "Network"), initial: settings.netStyle, preview: preview,
                                items: [("wifi-on", T("Wi-Fi 켜짐", "Wi-Fi On")), ("wifi-off", T("Wi-Fi 꺼짐", "Wi-Fi Off")),
                                        ("wifi-connected", T("Wi-Fi 연결", "Wi-Fi Connected")), ("wifi-disconnected", T("Wi-Fi 해제", "Wi-Fi Disconnected")),
                                        ("vpn-on", T("VPN 연결", "VPN Connected")), ("vpn-off", T("VPN 해제", "VPN Disconnected")),
                                        ("hotspot", T("핫스팟", "Hotspot"))])
            StylePreviewSection(title: T("블루투스", "Bluetooth"), initial: settings.btStyle, preview: preview,
                                items: [("bt-airpods", "AirPods"), ("bt-low", T("배터리 낮은 마우스", "Low-Battery Mouse")),
                                        ("bt-nobattery", T("배터리 정보 없음", "No Battery Info"))])
            StylePreviewSection(title: T("집중 모드", "Focus"), initial: settings.focusStyle, preview: preview,
                                items: [("focus-on", T("집중 모드 켜짐", "Focus On")), ("focus-off", T("집중 모드 꺼짐", "Focus Off"))])
            StylePreviewSection(title: T("배터리", "Battery"), initial: settings.batteryStyle, preview: preview,
                                items: [("charger", T("충전기 연결", "Charger Connected")), ("low", T("배터리 부족", "Low Battery")), ("full", T("완충", "Full"))])
            // 형태가 정해진 알림
            previewSection(T("컴팩트로만 표시", "Compact Only"),
                           [("hud-volume", T("음량 HUD", "Volume HUD")), ("hud-brightness", T("화면 밝기 HUD", "Display Brightness HUD")),
                            ("hud-keyboard", T("키보드 밝기 HUD", "Keyboard Brightness HUD")), ("download", T("다운로드", "Download")),
                            ("airdrop-send", T("에어드랍 보내기", "AirDrop Send")), ("recording", T("화면 녹화", "Screen Recording")),
                            ("call-active", T("통화 중", "On a Call")), ("lock", T("잠금화면 (5초)", "Lock Screen (5s)"))],
                           note: T("통화 중: 가짜 통화로 음소거·끊기를 눌러 볼 수 있고 30초 뒤 끝납니다. 잠금화면: 실제로 잠그지 않고 자물쇠·위젯을 5초 보여 줍니다.",
                                   "On a Call: a fake call where you can try Mute and End; it ends after 30 seconds. Lock Screen: shows the padlock and widget for 5 seconds without locking."))
            previewSection(T("상세로만 표시", "Detailed Only"),
                           [("call-incoming", T("수신 전화", "Incoming Call")), ("offline", T("네트워크 끊김", "Network Lost")),
                            ("airdrop-receive", T("에어드랍 받기", "AirDrop Receive")), ("screenshot", T("스크린샷", "Screenshot")),
                            ("timer-done", T("타이머 종료", "Timer Done")), ("calendar", T("일정 알림", "Event Alert"))],
                           note: T("수신 전화: 가짜 전화로 받기·거절을 눌러 볼 수 있고 30초 동안 조작이 없으면 끝납니다.",
                                   "Incoming Call: a fake call where you can try Accept and Decline; it ends after 30 seconds without interaction."))
        }
        .formStyle(.grouped)
    }

    private func previewSection(_ title: String, _ items: [(id: String, label: String)], note: String? = nil) -> some View {
        Section(title) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                ForEach(items, id: \.id) { item in
                    Button(item.label) { preview(item.id) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var about: some View {
        VStack(spacing: 8) {
            Text("Dynamic MacNotch").font(.title.bold())
            Text(T("버전 ", "Version ") + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")).foregroundStyle(.secondary)
            Text(T("Apple Silicon(M1 이상) · macOS 14 Sonoma 이상", "Apple Silicon (M1 or later) · macOS 14 Sonoma or later")).font(.caption).foregroundStyle(.secondary)
            Link("github.com/tjehddnr2864-hue/Dynamic-MacNotch", destination: URL(string: "https://github.com/tjehddnr2864-hue/Dynamic-MacNotch")!)
                .font(.caption)
            Text(T("애드혹 서명(공증되지 않음)", "Ad-hoc signed (not notarized)")).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 폴더 경로 설정: 현재 경로, '선택…'(폴더 고르기), '기본값'.
/// 화면 녹화·다운로드가 끝난 뒤 노치의 Finder 바로가기가 이 폴더를 연다.
struct FolderSetting: View {
    var title: String
    @Binding var path: String
    var defaultPath: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text((path.isEmpty ? defaultPath : path).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 220, alignment: .trailing)
                Button(T("선택…", "Choose…")) { choose() }
                if path != defaultPath {
                    Button(T("기본값", "Default")) { path = defaultPath }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path.isEmpty ? defaultPath : path)
        panel.prompt = T("선택", "Choose")
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

/// 컴팩트·상세를 고를 수 있는 알림 묶음의 미리보기. 고른 형태는 이 미리보기에만 쓰이고 실제 설정은 그대로다.
private struct StylePreviewSection: View {
    var title: String
    var preview: (String) -> Void
    var items: [(id: String, label: String)]
    private let styleState: State<AlertStyle>

    init(title: String, initial: AlertStyle, preview: @escaping (String) -> Void, items: [(id: String, label: String)]) {
        self.title = title
        self.preview = preview
        self.items = items
        styleState = State(initialValue: initial)
    }

    var body: some View {
        Section {
            Picker(T("표시 형태", "Style"), selection: styleState.projectedValue) {
                ForEach(AlertStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                ForEach(items, id: \.id) { item in
                    Button(item.label) { preview(item.id + "@" + styleState.wrappedValue.rawValue) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Text(T("컴팩트·상세 선택", "Compact or Detailed")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
