import SwiftUI

// 진행 중인 활동을 보여 주는 기능의 페이지 (미디어, 다운로드, 에어드랍·트레이, 스크린샷, 화면 녹화, 잠금화면, 일정)

struct MediaSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsForm {
            SettingsSection(SectionTitle.show) {
                Toggle(T("곡 바뀜 알림", "New song alert"), detail: T("곡이 바뀌면 잠깐 크게 보여 줍니다.", "Briefly shows the new song."), isOn: $settings.mediaShowTrackChange)
                Indented(enabled: settings.mediaShowTrackChange) {
                    Toggle(T("음악 앱에서만", "Music apps only"), detail: T("Apple Music과 Spotify의 곡만 알립니다.", "Only for Apple Music and Spotify."), isOn: $settings.mediaTrackChangeMusicOnly)
                }
            }
            SettingsSection(SectionTitle.style) {
                ValueMenu(title: T("일시정지 후 숨김", "Hide after pause"), selection: $settings.mediaHideAfterPause, values: Choices.mediaHide,
                          zero: T("숨기지 않음", "Never"), label: Format.seconds)
            }
            SettingsSection(T("재생 소스", "Source"),
                            footer: T("켠 소스의 재생만 노치에 보입니다.", "Only the sources you turn on show in the notch."),
                            more: T("모든 미디어를 켜면 나머지 스위치가 꺼지고, 하나라도 켜면 모든 미디어가 꺼집니다. 다 끄면 모든 미디어로 돌아갑니다. YouTube는 macOS가 사이트 주소를 알려 주지 않아, 브라우저(Safari·Chrome·Edge·Brave·Arc 등)에 열린 탭의 주소와 제목을 물어 확인합니다. 처음 한 번 브라우저 제어(자동화) 권한을 묻고, 탭 주소는 확인에만 쓰고 저장하지 않습니다. Firefox는 탭 주소를 알려 주지 않아 YouTube로 확인할 수 없습니다.",
                                    "Turning on All Media turns the others off, and turning any of them on turns All Media off. Turning them all off goes back to All Media. macOS doesn't say which site is playing, so for YouTube the app asks your browser (Safari, Chrome, Edge, Brave, Arc and others) for the addresses and titles of its open tabs. The browser asks once for Automation permission; tab addresses are only checked, never stored. Firefox doesn't share tab addresses, so YouTube can't be recognized there.")) {
                sourceToggles
            }
            PreviewSection([(.mediaStart, T("재생 테스트 시작", "Start Playback Test")), (.mediaStop, T("테스트 중지", "Stop Test"))])
        }
    }
}

extension MediaSettingsPage {
    @ViewBuilder
    var sourceToggles: some View {
        let list = settings.mediaSourceList
        Toggle(T("모든 미디어", "All Media"), detail: T("브라우저·동영상 앱을 포함한 모든 재생", "Everything that plays, including browsers and video apps"),
               isOn: Binding(get: { list.isEmpty }, set: { if $0 { settings.setMediaSources([]) } }))
        ForEach(MediaSource.pickable) { source in
            Toggle(source.label, isOn: Binding(get: { list.contains(source) },
                                               set: { settings.setMediaSources(MediaSource.toggled(source, on: $0, in: list)) }))
            if source == .youtube {
                Indented(enabled: list.contains(.youtube)) {
                    Choice(T("YouTube 범위", "YouTube scope"), detail: T("music.youtube.com만 보일지 고릅니다.", "Whether to show only music.youtube.com."), selection: $settings.mediaYouTubeScope)
                }
            }
        }
    }
}

struct DownloadSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsForm {
            SettingsSection(SectionTitle.show) {
                Toggle(T("다운로드 진행 표시", "Show download progress"), isOn: $settings.downloadEnabled)
            }
            SettingsSection(SectionTitle.style, disabled: !settings.downloadEnabled, disabledNote: T("다운로드 진행 표시를 켜면 바꿀 수 있습니다.", "Turn on download progress to change this.")) {
                ProgressStylePicker(selection: $settings.downloadStyle)
            }
            SettingsSection(SectionTitle.details, disabled: !settings.downloadEnabled) {
                FolderSetting(title: T("다운로드 폴더", "Downloads folder"), path: $settings.downloadFolder,
                              defaultPath: AppSettings.defaultDownloadFolder)
                ListField(title: T("추가로 감시할 폴더 경로", "Extra folders to watch"), text: $settings.downloadFolders)
            }
            PreviewSection([(.download, T("다운로드", "Download"))])
        }
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
        SettingsForm {
            SettingsSection(SectionTitle.show, footer: T("파일을 든 채 노치 옆 막대로 가면 다른 화면으로 바뀝니다.", "Hold a file over the bar beside the notch to switch screens."), more: T("에어드랍·트레이와 AI 채팅이 모두 켜져 있으면, 파일을 든 채 노치 옆의 세로 막대로 커서를 옮겨 다른 화면으로 바꿀 수 있습니다. 막대의 방향은 홈 페이지 순서를 따릅니다.",
                                                        "When AirDrop & Tray and AI Chat are both on, move the cursor to the vertical bar beside the notch while holding a file to switch screens. The bar's side follows the Home page order.")) {
                Choice(T("에어드랍·트레이", "AirDrop & Tray"), selection: $settings.trayMode)
                Choice(T("끌어올 때 보일 화면", "When dragging files"), selection: dragPage)
                    .disabled(settings.trayMode == .off || !settings.chatEnabled)
            }
            SettingsSection(SectionTitle.style) {
                ProgressStylePicker(selection: $settings.airdropStyle)
            }
            SettingsSection(SectionTitle.details, footer: T("자동 정리는 원본 파일을 지우지 않습니다.", "Auto-clean never deletes original files."), more: T("자동 정리는 트레이에 넣은 지 그 시간이 지난 항목을 목록에서 뺍니다. 원본 파일은 그대로이고, 복사본으로 보관한 파일은 복사본이 지워집니다. 파일을 들고 화면 위쪽 감지 높이 안으로 오면, 가장자리에 닿기 전에 노치가 먼저 열려 Mission Control이 뜨지 않게 합니다.", "Auto-clean removes items from the tray after that time. Original files stay where they are; files kept as copies have their copy deleted. When you drag a file into this zone at the top of the screen, the notch opens before you reach the edge, so Mission Control doesn't trigger."),
                            disabled: settings.trayMode == .off, disabledNote: T("에어드랍·트레이를 켜면 바꿀 수 있습니다.", "Turn on AirDrop & Tray to change this.")) {
                Toggle(T("복사본으로 보관", "Keep copies"), detail: T("원본을 옮기거나 지워도 트레이에 남습니다.", "Items stay even if the original moves."), isOn: $settings.trayKeepCopies)
                ValueMenu(title: T("트레이 자동 정리", "Auto-clean tray"), selection: $settings.trayCleanupMinutes,
                          values: Choices.trayCleanup, zero: T("끄기", "Off")) { Format.period(minutes: $0) }
                ValueSlider(title: T("드래그 감지 높이", "Drag detection height"), value: $settings.dragZoneHeight, range: 60...200, step: 10, format: Format.points)
            }
            PreviewSection([(.airdropSend, T("에어드랍 보내기", "AirDrop Send")), (.airdropReceive, T("에어드랍 받기", "AirDrop Receive"))])
        }
    }
}


struct ScreenshotSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsForm {
            SettingsSection(SectionTitle.show) {
                Toggle(T("스크린샷 미리보기", "Screenshot preview"), isOn: $settings.screenshotEnabled)
            }
            SettingsSection(SectionTitle.style,
                            footer: T("클립보드 스크린샷은 트레이에서 빠질 때 휴지통으로 갑니다.", "Clipboard screenshots go to the Trash when they leave the tray."),
                            more: T("파일 트레이를 고르면 카드의 에어드랍 버튼 자리에 트레이 버튼이 나옵니다. 파일로 저장된 스크린샷은 그 파일을 트레이에 넣고, 클립보드 스크린샷은 원본이 따로 없어 트레이가 PNG 파일로 보관합니다. 트레이 자동 정리 시간이 지나거나 직접 빼면 그 파일은 지우지 않고 휴지통으로 보냅니다.",
                                    "With File Tray, the Tray button takes the place of AirDrop on the card. A screenshot saved as a file is added as that file; a clipboard screenshot has no original, so the tray keeps it as a PNG. When auto-clean removes it or you take it out, the file goes to the Trash instead of being deleted."),
                            disabled: !settings.screenshotEnabled, disabledNote: T("스크린샷 미리보기를 켜면 바꿀 수 있습니다.", "Turn on Screenshot preview to change this.")) {
                ValueMenu(title: T("자동 닫힘", "Auto-close"), selection: $settings.screenshotAutoClose, values: Choices.screenshotClose, label: Format.seconds)
                Choice(T("보내기 버튼", "Send button"), detail: T("에어드랍·트레이를 끄면 에어드랍으로 보입니다.", "Shows AirDrop when AirDrop & Tray is off."), selection: $settings.screenshotSend)
                    .disabled(settings.trayMode == .off)
            }
            SettingsSection(SectionTitle.details, disabled: !settings.screenshotEnabled) {
                Choice(T("감지 대상", "Detect"), selection: $settings.screenshotSource)
                FolderSetting(title: T("저장 폴더", "Save folder"), path: $settings.screenshotFolder,
                              defaultPath: AppSettings.defaultRecordingFolder)
                Toggle(T("JPEG로 저장", "Save as JPEG"), isOn: $settings.screenshotJPEG)
            }
            PreviewSection([(.screenshot, T("스크린샷", "Screenshot"))])
        }
    }
}

struct RecordingSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsForm {
            SettingsSection(SectionTitle.show) {
                Toggle(T("화면 녹화 표시", "Show screen recording"), isOn: $settings.recordingEnabled)
            }
            SettingsSection(SectionTitle.style, footer: T("계속 표시는 녹화하는 동안 노치에 녹화 시간을 보여 줍니다.", "Keep Showing displays the elapsed time in the notch while recording."),
                            disabled: !settings.recordingEnabled, disabledNote: T("화면 녹화 표시를 켜면 바꿀 수 있습니다.", "Turn on screen recording to change this.")) {
                Choice(T("표시 형태", "Style"), selection: $settings.recordingStyle)
            }
            SettingsSection(SectionTitle.details, disabled: !settings.recordingEnabled) {
                FolderSetting(title: T("저장 폴더", "Save folder"), path: $settings.recordingFolder,
                              defaultPath: AppSettings.defaultRecordingFolder)
            }
            PreviewSection([(.recording, T("화면 녹화", "Screen Recording"))])
        }
    }
}

struct LockSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsForm {
            SettingsSection(SectionTitle.show) {
                Toggle(T("잠금 애니메이션", "Lock animation"), detail: T("잠기면 자물쇠를, 풀리면 열리는 모습을 보입니다.", "Shows a padlock when locked and opens it on unlock."), isOn: $settings.lockNotchEnabled)
                Toggle(T("잠금화면 미디어 위젯", "Lock screen media widget"), detail: T("음악을 재생하는 동안 잠금화면에 보입니다.", "Shown on the lock screen while music plays."), isOn: $settings.lockMediaWidget)
            }
            SettingsSection(SectionTitle.style, footer: T("앨범아트를 누르면 전체화면 플레이어로 커집니다.", "Click the album art for a full-screen player."), more: T("위젯은 프로필 사진·암호 입력란 바로 위에 표시됩니다. 앨범아트를 누르면 전체화면 플레이어로 커집니다. 잠금화면에 창을 띄우는 기능은 비공개 API를 쓰므로 macOS 업데이트에 따라 동작하지 않을 수 있습니다.", "The widget appears just above your profile picture and password field. Click the album art for a full-screen player. Showing windows on the lock screen uses private APIs and may stop working after a macOS update."),
                            disabled: !settings.lockMediaWidget, disabledNote: T("잠금화면 미디어 위젯을 켜면 바꿀 수 있습니다.", "Turn on the lock screen media widget to change this.")) {
                Toggle(T("곡 정보 숨기기", "Hide song info"), detail: T("잠금화면 위젯에 곡 제목을 보이지 않습니다.", "Hides the song title in the lock screen widget."), isOn: $settings.lockHideTrackInfo)
            }
            SettingsSection(T("가사", "Lyrics"), footer: T("실시간 가사는 곡 정보를 LRCLIB로 보내 받아옵니다.", "Live lyrics send song info to LRCLIB."), more: T("실시간 가사는 곡 제목·아티스트·앨범을 외부 가사 서비스 LRCLIB(lrclib.net)로 보내 받아옵니다. 끄면 Music 앱에 저장된 가사만 표시합니다.", "Live lyrics send the song title, artist and album to LRCLIB (lrclib.net). When off, only lyrics stored in the Music app are shown."),
                            disabled: !settings.lockMediaWidget) {
                Toggle(T("전체화면 가사", "Full-screen lyrics"), detail: T("Apple Music 전체화면 플레이어에 가사를 보입니다.", "Shows lyrics in the Apple Music full-screen player."), isOn: $settings.lyricsEnabled)
                Indented(enabled: settings.lyricsEnabled) {
                    Toggle(T("실시간 가사", "Live lyrics"), detail: T("곡에 맞춰 넘어가는 가사를 받아옵니다.", "Fetches lyrics that follow the song."), isOn: $settings.lyricsOnline)
                }
                ListChoice(T("가사 글자 크기", "Lyrics size"), selection: $settings.lyricsSize,
                           items: [(0, T("작게", "Small")), (1, T("보통", "Medium")), (2, T("크게", "Large"))])
                    .disabled(!settings.lyricsEnabled)
            }
            PreviewSection([(.lock, T("자물쇠·위젯 (5초)", "Padlock & Widget (5s)"))])
        }
    }
}

struct CalendarSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    private var isOn: Bool { settings.isHomeFeatureOn("calendar") }

    var body: some View {
        SettingsForm {
            SettingsSection(SectionTitle.show, footer: T("끄면 일정 감시와 알림도 멈춥니다.", "When off, calendar watching and alerts stop too.")) {
                HomePageToggle(settings: settings, key: "calendar", title: T("홈에 오늘 일정", "Today in Home"))
                ValueMenu(title: T("일정 알림", "Event alerts"), selection: $settings.calendarAlertMinutes, values: Choices.calendarAlert, zero: T("끄기", "Off")) {
                    T("\(Int($0))분 전", "\(Int($0)) min before")
                }
                .disabled(!isOn)
            }
            SettingsSection(SectionTitle.live, disabled: !isOn, disabledNote: T("홈에 오늘 일정을 켜면 바꿀 수 있습니다.", "Turn on Today in Home to change this.")) {
                Toggle(T("다음 일정", "Next event"), detail: T("시작 시각을, 진행 중이면 끝나는 시각을 보입니다.", "Shows the start time, or the end time while it's on."), isOn: $settings.calendarPinned)
            }
            PreviewSection([(.calendar, T("일정 알림", "Event Alert")), (.calendarPinned, T("다음 일정", "Next Event"))])
        }
    }
}
