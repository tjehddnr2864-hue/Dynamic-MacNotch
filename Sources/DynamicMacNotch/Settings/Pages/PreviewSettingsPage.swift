import SwiftUI

/// 미리보기: 모든 기능을 한곳에서 노치에 띄워 본다. 실제 설정·파일·통화에는 영향이 없다.
struct PreviewSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    footnote(T("각 버튼을 누르면 노치에 해당 기능이 미리 표시됩니다. 실제 설정·파일·통화에는 영향이 없습니다.",
                               "Each button previews that feature in the notch. Your real settings, files and calls are not affected."))
                    Spacer()
                    Button(T("모든 미리보기 중지", "Stop All Previews")) { PreviewID.stopAll.run() }
                }
            }
            SettingsSection(T("미디어", "Media"), footer: T("테스트 곡이 노치에 재생됩니다. 길게 눌러 플레이어를 열고 재생·다음·이전·재생 바를 시험해 보세요. 30초 동안 조작이 없으면 자동으로 중지됩니다.",
                                                         "A test song plays in the notch. Long-press to open the player and try play, next, previous and the progress bar. It stops automatically after 30 seconds without interaction.")) {
                HStack {
                    Button(T("재생 테스트 시작", "Start Playback Test")) { PreviewID.mediaStart.run() }
                    Button(T("테스트 중지", "Stop Test")) { PreviewID.mediaStop.run() }
                }
            }
            // 컴팩트·상세를 고를 수 있는 알림: 묶음마다 형태를 골라 미리 본다 (실제 설정은 바뀌지 않음)
            StylePreviewSection(title: T("네트워크", "Network"), initial: settings.netStyle,
                                items: [(.wifiOn, T("Wi-Fi 켜짐", "Wi-Fi On")), (.wifiOff, T("Wi-Fi 꺼짐", "Wi-Fi Off")),
                                        (.wifiConnected, T("Wi-Fi 연결", "Wi-Fi Connected")), (.wifiDisconnected, T("Wi-Fi 해제", "Wi-Fi Disconnected")),
                                        (.vpnOn, T("VPN 연결", "VPN Connected")), (.vpnOff, T("VPN 해제", "VPN Disconnected")),
                                        (.hotspot, T("핫스팟", "Hotspot"))])
            StylePreviewSection(title: T("블루투스", "Bluetooth"), initial: settings.btStyle,
                                items: [(.airpods, "AirPods"), (.btLow, T("배터리 낮은 마우스", "Low-Battery Mouse")),
                                        (.btNoBattery, T("배터리 정보 없음", "No Battery Info"))])
            StylePreviewSection(title: T("집중 모드", "Focus"), initial: settings.focusStyle,
                                items: [(.focusOn, T("집중 모드 켜짐", "Focus On")), (.focusOff, T("집중 모드 꺼짐", "Focus Off"))])
            StylePreviewSection(title: T("배터리", "Battery"), initial: settings.batteryStyle,
                                items: [(.charger, T("충전기 연결", "Charger Connected")), (.low, T("배터리 부족", "Low Battery")), (.full, T("완충", "Fully Charged"))])
            StylePreviewSection(title: "Claude Code · Codex", initial: settings.agentStyle,
                                items: [(.agentDone, T("작업 완료", "Task Finished"))])
            // 형태가 정해진 알림
            fixedSection(T("컴팩트로만 표시", "Compact Only"),
                         [(.hudVolume, T("음량 HUD", "Volume HUD")), (.hudBrightness, T("화면 밝기 HUD", "Display Brightness HUD")),
                          (.hudKeyboard, T("키보드 밝기 HUD", "Keyboard Brightness HUD")), (.download, T("다운로드", "Download")),
                          (.airdropSend, T("에어드랍 보내기", "AirDrop Send")), (.recording, T("화면 녹화", "Screen Recording")),
                          (.callActive, T("통화 중", "On a Call")), (.lock, T("잠금화면 (5초)", "Lock Screen (5s)")),
                          (.aiUsage, T("AI 사용량", "AI Usage")), (.resourceLive, T("자원 사용량", "Resource Usage")), (.monitorLive, T("AI 및 자원", "AI & Resource")), (.chargingPinned, T("충전 중", "Charging")),
                          (.vpnPinned, "VPN"), (.calendarPinned, T("다음 일정", "Next Event"))],
                         note: T("통화 중: 가짜 통화로 음소거·끊기를 눌러 볼 수 있고 30초 뒤 끝납니다. 잠금화면: 실제로 잠그지 않고 자물쇠·위젯을 5초 보여 줍니다.",
                                 "On a Call: a fake call where you can try Mute and End; it ends after 30 seconds. Lock Screen: shows the padlock and widget for 5 seconds without locking."))
            fixedSection(T("상세로만 표시", "Detailed Only"),
                         [(.callIncoming, T("수신 전화", "Incoming Call")), (.offline, T("네트워크 끊김", "Network Lost")),
                          (.airdropReceive, T("에어드랍 받기", "AirDrop Receive")), (.screenshot, T("스크린샷", "Screenshot")),
                          (.timerDone, T("타이머 종료", "Timer Done")), (.calendar, T("일정 알림", "Event Alert")),
                          (.updateDone, T("업데이트 완료", "Update Finished")), (.chatDone, T("AI 채팅 답변 완료", "AI Chat Answer Ready"))],
                         note: T("수신 전화: 가짜 전화로 받기·거절을 눌러 볼 수 있고 30초 동안 조작이 없으면 끝납니다.",
                                 "Incoming Call: a fake call where you can try Accept and Decline; it ends after 30 seconds without interaction."))
        }
        .settingsForm()
    }

    private func fixedSection(_ title: String, _ items: [(id: PreviewID, label: String)], note: String) -> some View {
        SettingsSection(title, footer: note) {
            PreviewButtonGrid(items: items) { $0.run() }
        }
    }
}

private struct PreviewButtonGrid: View {
    var items: [(id: PreviewID, label: String)]
    var run: (PreviewID) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
            ForEach(items, id: \.id) { item in
                Button(item.label) { run(item.id) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 컴팩트·상세를 고를 수 있는 알림 묶음. 고른 형태는 이 미리보기에만 쓰이고 실제 설정은 그대로다.
private struct StylePreviewSection: View {
    var title: String
    var items: [(id: PreviewID, label: String)]
    private let styleState: State<AlertStyle>

    init(title: String, initial: AlertStyle, items: [(id: PreviewID, label: String)]) {
        self.title = title
        self.items = items
        styleState = State(initialValue: initial)
    }

    var body: some View {
        SettingsSection(title) {
            AlertStylePicker(selection: styleState.projectedValue)
            PreviewButtonGrid(items: items) { $0.run(style: styleState.wrappedValue) }
        }
    }
}
