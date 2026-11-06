import SwiftUI

// 진행 중인 활동을 보여 주는 기능의 페이지 (미디어, 다운로드, 에어드랍·트레이, 스크린샷, 화면 녹화, 잠금화면, 일정)

struct MediaSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SettingsSection(SectionTitle.show) {
                Toggle(T("곡이 바뀌면 잠깐 크게 표시", "Briefly show the new song"), isOn: $settings.mediaShowTrackChange)
                Indented(enabled: settings.mediaShowTrackChange) {
                    Toggle(T("Apple Music·Spotify에서만", "Only for Apple Music and Spotify"), isOn: $settings.mediaTrackChangeMusicOnly)
                }
            }
            SettingsSection(SectionTitle.style) {
                ValueMenu(title: T("일시정지 후 숨김", "Hide after pause"), selection: $settings.mediaHideAfterPause, values: [10, 30, 60],
                          zero: T("숨기지 않음", "Never")) { T("\(Int($0))초", "\(Int($0))s") }
            }
            SettingsSection(SectionTitle.details) {
                SegmentedChoice(T("재생 소스", "Source"), selection: $settings.mediaSource)
            }
            PreviewSection([(.mediaStart, T("재생 테스트 시작", "Start Playback Test")), (.mediaStop, T("테스트 중지", "Stop Test"))])
        }
        .settingsForm()
    }
}

struct DownloadSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SettingsSection(SectionTitle.show) {
                Toggle(T("다운로드 진행 표시", "Show download progress"), isOn: $settings.downloadEnabled)
            }
            SettingsSection(SectionTitle.style, disabled: !settings.downloadEnabled) {
                ProgressStylePicker(selection: $settings.downloadStyle)
            }
            SettingsSection(SectionTitle.details, disabled: !settings.downloadEnabled) {
                FolderSetting(title: T("다운로드 폴더", "Downloads folder"), path: $settings.downloadFolder,
                              defaultPath: AppSettings.defaultDownloadFolder)
                ListField(title: T("추가로 감시할 폴더 경로", "Extra folders to watch"), text: $settings.downloadFolders)
            }
            PreviewSection([(.download, T("다운로드", "Download"))])
        }
        .settingsForm()
    }
}

struct TraySettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    /// 둘 다 켜져 있을 때만 고를 수 있다. 하나만 켜져 있으면 그 화면이 뜬다.
    private var dragPage: Binding<FileDragPage> {
        Binding(get: {
            if !settings.chatEnabled { return .tray }
            return settings.trayMode == .off ? .chat : settings.fileDragPage
        }, set: { settings.fileDragPage = $0 })
    }

    var body: some View {
        Form {
            SettingsSection(SectionTitle.show, footer: T("에어드랍·트레이와 AI 채팅이 모두 켜져 있으면, 파일을 든 채 노치 옆의 세로 막대로 커서를 옮겨 다른 화면으로 바꿀 수 있습니다. 막대의 방향은 홈 페이지 순서를 따릅니다.",
                                                        "When AirDrop & Tray and AI Chat are both on, move the cursor to the vertical bar beside the notch while holding a file to switch screens. The bar's side follows the Home page order.")) {
                SegmentedChoice(T("에어드랍·트레이", "AirDrop & Tray"), selection: $settings.trayMode)
                SegmentedChoice(T("파일을 끌어왔을 때 보일 화면", "Screen shown when dragging a file"), selection: dragPage)
                    .disabled(settings.trayMode == .off || !settings.chatEnabled)
            }
            SettingsSection(SectionTitle.style) {
                ProgressStylePicker(selection: $settings.airdropStyle)
            }
            SettingsSection(SectionTitle.details, footer: T("파일을 들고 화면 위쪽 감지 높이 안으로 오면, 가장자리에 닿기 전에 노치가 먼저 열려 Mission Control이 뜨지 않게 합니다.", "When you drag a file into this zone at the top of the screen, the notch opens before you reach the edge, so Mission Control doesn't trigger."),
                            disabled: settings.trayMode == .off) {
                Toggle(T("트레이에 복사본 보관 (원본이 옮겨져도 유지)", "Keep copies in the tray (survive moves)"), isOn: $settings.trayKeepCopies)
                ValueMenu(title: T("트레이 자동 정리", "Auto-clean tray"), selection: $settings.trayCleanupDays, values: [1, 7], zero: T("끄기", "Off")) {
                    T("\(Int($0))일", $0 == 1 ? "1 day" : "\(Int($0)) days")
                }
                ValueSlider(title: T("드래그 감지 높이", "Drag detection height"), value: $settings.dragZoneHeight, range: 60...200, step: 10) { "\(Int($0))pt" }
            }
            PreviewSection([(.airdropSend, T("에어드랍 보내기", "AirDrop Send")), (.airdropReceive, T("에어드랍 받기", "AirDrop Receive"))])
        }
        .settingsForm()
    }
}

struct ScreenshotSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SettingsSection(SectionTitle.show) {
                Toggle(T("스크린샷 미리보기", "Screenshot preview"), isOn: $settings.screenshotEnabled)
            }
            SettingsSection(SectionTitle.style, disabled: !settings.screenshotEnabled) {
                ValueMenu(title: T("자동 닫힘", "Auto-close"), selection: $settings.screenshotAutoClose, values: [5, 10, 30]) { T("\(Int($0))초", "\(Int($0))s") }
            }
            SettingsSection(SectionTitle.details, disabled: !settings.screenshotEnabled) {
                SegmentedChoice(T("감지 대상", "Detect"), selection: $settings.screenshotSource)
                FolderSetting(title: T("저장 폴더", "Save folder"), path: $settings.screenshotFolder,
                              defaultPath: AppSettings.defaultRecordingFolder)
                Toggle(T("JPEG로 저장", "Save as JPEG"), isOn: $settings.screenshotJPEG)
            }
            PreviewSection([(.screenshot, T("스크린샷", "Screenshot"))])
        }
        .settingsForm()
    }
}

struct RecordingSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SettingsSection(SectionTitle.show) {
                Toggle(T("화면 녹화 표시", "Show screen recording"), isOn: $settings.recordingEnabled)
            }
            SettingsSection(SectionTitle.style, footer: T("계속 표시는 녹화하는 동안 노치에 녹화 시간을 보여 줍니다.", "Keep Showing displays the elapsed time in the notch while recording."),
                            disabled: !settings.recordingEnabled) {
                SegmentedChoice(T("표시 형태", "Style"), selection: $settings.recordingStyle)
            }
            SettingsSection(SectionTitle.details, disabled: !settings.recordingEnabled) {
                FolderSetting(title: T("저장 폴더", "Save folder"), path: $settings.recordingFolder,
                              defaultPath: AppSettings.defaultRecordingFolder)
            }
            PreviewSection([(.recording, T("화면 녹화", "Screen Recording"))])
        }
        .settingsForm()
    }
}

struct LockSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SettingsSection(SectionTitle.show) {
                Toggle(T("잠기면 자물쇠, 풀리면 열림 애니메이션", "Show a lock when locked and an unlock animation"), isOn: $settings.lockNotchEnabled)
                Toggle(T("음악 재생 중 잠금화면 미디어 위젯", "Lock screen media widget while playing"), isOn: $settings.lockMediaWidget)
            }
            SettingsSection(SectionTitle.style, footer: T("위젯은 프로필 사진·암호 입력란 바로 위에 표시됩니다. 앨범아트를 누르면 전체화면 플레이어로 커집니다. 잠금화면에 창을 띄우는 기능은 비공개 API를 쓰므로 macOS 업데이트에 따라 동작하지 않을 수 있습니다.", "The widget appears just above your profile picture and password field. Click the album art for a full-screen player. Showing windows on the lock screen uses private APIs and may stop working after a macOS update."),
                            disabled: !settings.lockMediaWidget) {
                Toggle(T("잠금화면에서 곡 정보 숨기기", "Hide song info on the lock screen"), isOn: $settings.lockHideTrackInfo)
            }
            SettingsSection(T("가사", "Lyrics"), footer: T("실시간 가사는 곡 제목·아티스트·앨범을 외부 가사 서비스 LRCLIB(lrclib.net)로 보내 받아옵니다. 끄면 Music 앱에 저장된 가사만 표시합니다.", "Live lyrics send the song title, artist and album to LRCLIB (lrclib.net). When off, only lyrics stored in the Music app are shown."),
                            disabled: !settings.lockMediaWidget) {
                Toggle(T("전체화면에서 가사 표시 (Apple Music)", "Show lyrics in full screen (Apple Music)"), isOn: $settings.lyricsEnabled)
                Indented(enabled: settings.lyricsEnabled) {
                    Toggle(T("실시간(시간 동기) 가사 가져오기", "Fetch live (time-synced) lyrics"), isOn: $settings.lyricsOnline)
                }
                Picker(T("가사 글자 크기", "Lyrics size"), selection: $settings.lyricsSize) {
                    Text(T("작게", "Small")).tag(0)
                    Text(T("보통", "Medium")).tag(1)
                    Text(T("크게", "Large")).tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(!settings.lyricsEnabled)
            }
            PreviewSection([(.lock, T("자물쇠·위젯 (5초)", "Padlock & Widget (5s)"))])
        }
        .settingsForm()
    }
}

struct CalendarSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    private var isOn: Bool { settings.isHomeFeatureOn("calendar") }

    var body: some View {
        Form {
            SettingsSection(SectionTitle.show, footer: T("끄면 일정 감시와 알림도 멈춥니다.", "When off, calendar watching and alerts stop too.")) {
                HomePageToggle(settings: settings, key: "calendar", title: T("홈에 오늘 일정 페이지 표시", "Show Today in Home"))
                ValueMenu(title: T("일정 알림", "Event alerts"), selection: $settings.calendarAlertMinutes, values: [5, 10, 15], zero: T("끄기", "Off")) {
                    T("\(Int($0))분 전", "\(Int($0)) min before")
                }
                .disabled(!isOn)
            }
            SettingsSection(SectionTitle.live, disabled: !isOn) {
                Toggle(T("다음 일정 (시작 시각, 진행 중이면 끝나는 시각)", "Next event (start time, or end time while it's on)"), isOn: $settings.calendarPinned)
            }
            PreviewSection([(.calendar, T("일정 알림", "Event Alert")), (.calendarPinned, T("다음 일정", "Next Event"))])
        }
        .settingsForm()
    }
}
