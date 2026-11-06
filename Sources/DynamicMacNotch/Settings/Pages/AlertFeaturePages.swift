import SwiftUI

// 시스템 상태를 알림으로 보여 주는 기능의 페이지 (네트워크, 블루투스, 집중 모드, 통화, 배터리, HUD)

struct NetworkSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    private var anyAlertOn: Bool { settings.netWifiPower || settings.netWifiConnection || settings.netVPN || settings.netHotspot }

    var body: some View {
        Form {
            SettingsSection(SectionTitle.show) {
                Toggle(T("Wi-Fi 켜짐·꺼짐", "Wi-Fi on and off"), isOn: $settings.netWifiPower)
                Toggle(T("Wi-Fi 연결·해제", "Wi-Fi connected and disconnected"), isOn: $settings.netWifiConnection)
                Toggle(T("VPN 연결·해제", "VPN connected and disconnected"), isOn: $settings.netVPN)
                Toggle(T("핫스팟 연결·해제", "Hotspot connected and disconnected"), isOn: $settings.netHotspot)
            }
            SettingsSection(SectionTitle.live, footer: T("VPN 상시 표시를 켜면 연결된 국가를 알기 위해, VPN이 연결된 동안 네트워크가 바뀔 때와 1분마다 공인 IP를 국가 조회 서비스(country.is, 실패 시 ipinfo.io)에 보냅니다. 끄면 조회하지 않습니다.",
                                                        "With the VPN Live Activity on, your public IP is sent to a country lookup service (country.is, or ipinfo.io if that fails) when the network changes and once a minute while a VPN is connected. When off, no lookup happens.")) {
                Toggle(T("VPN 연결 중 (왼쪽 아이콘, 오른쪽 연결 국가)", "While on a VPN (left: icon, right: country)"), isOn: $settings.vpnPinned)
                Toggle(T("핫스팟 연결 중", "While on a hotspot"), isOn: $settings.hotspotPinned)
            }
            SettingsSection(SectionTitle.style, disabled: !anyAlertOn) {
                AlertStylePicker(selection: $settings.netStyle)
                AlertDurationMenu(selection: $settings.netDuration)
            }
            SettingsSection(SectionTitle.details, footer: T("핫스팟은 '데이터 절약 네트워크' 여부로 추정합니다. 잘 안 잡히면 iPhone의 Wi-Fi 이름을 적어 주세요. Wi-Fi 이름 표시에는 위치 서비스 권한이 필요합니다.",
                                                           "Hotspots are detected from the Low Data Mode network flag. If yours isn't detected, enter your iPhone's Wi-Fi name. Showing Wi-Fi names requires Location Services permission.")) {
                ListField(title: T("핫스팟으로 볼 Wi-Fi 이름", "Wi-Fi names to treat as hotspots"), text: $settings.hotspotSSIDs)
            }
            PreviewSection([(.wifiConnected, T("Wi-Fi 연결", "Wi-Fi Connected")), (.vpnOn, T("VPN 연결", "VPN Connected")),
                            (.hotspot, T("핫스팟", "Hotspot")), (.offline, T("네트워크 끊김", "Network Lost"))])
        }
        .settingsForm()
    }
}

struct BluetoothSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SettingsSection(SectionTitle.show) {
                Toggle(T("액세서리가 연결되면 표시", "Show when an accessory connects"), isOn: $settings.btEnabled)
            }
            SettingsSection(SectionTitle.style, footer: T("배터리 표시는 컴팩트에 적용되고, 상세에서는 항상 백분율로 보입니다.", "Battery display applies to Compact; Detailed always shows a percentage."),
                            disabled: !settings.btEnabled) {
                AlertStylePicker(selection: $settings.btStyle)
                SegmentedChoice(T("배터리 표시", "Battery display"), selection: $settings.btBattery)
            }
            SettingsSection(SectionTitle.details, disabled: !settings.btEnabled) {
                ListField(title: T("알림을 끌 기기 이름", "Devices to ignore"), text: $settings.btBlocklist)
            }
            PreviewSection([(.airpods, "AirPods"), (.btLow, T("배터리 낮은 마우스", "Low-Battery Mouse")),
                            (.btNoBattery, T("배터리 정보 없음", "No Battery Info"))])
        }
        .settingsForm()
    }
}

struct FocusSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SettingsSection(SectionTitle.show) {
                Toggle(T("집중 모드 켜짐·꺼짐", "Focus on and off"), isOn: $settings.focusEnabled)
            }
            SettingsSection(SectionTitle.live) {
                Toggle(T("집중 모드가 켜진 동안", "While Focus is on"), isOn: $settings.focusPinned)
            }
            SettingsSection(SectionTitle.style, disabled: !settings.focusEnabled) {
                AlertStylePicker(selection: $settings.focusStyle)
                AlertDurationMenu(selection: $settings.focusDuration)
            }
            SettingsSection(SectionTitle.details, footer: T("모드 이름·아이콘은 전체 디스크 접근 권한이 있을 때만 표시됩니다. 없으면 '집중 모드 켬/끔'으로 표시합니다.", "Mode names and icons require Full Disk Access. Without it, alerts just say Focus On or Off.")) {
                ListField(title: T("표시하지 않을 모드 이름", "Modes to ignore"), text: $settings.focusExcluded)
            }
            PreviewSection([(.focusOn, T("켜짐", "On")), (.focusOff, T("꺼짐", "Off"))])
        }
        .settingsForm()
    }
}

struct CallSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            SettingsSection(SectionTitle.show, footer: T("수신 전화는 상세 카드(받기·거절), 통화 중에는 노치 양옆에 경과 시간을 표시합니다. 손쉬운 사용 권한이 필요합니다.", "Incoming calls show a detailed card (Accept, Decline); during a call the notch shows the elapsed time. Requires Accessibility permission.")) {
                Toggle(T("수신 전화와 통화 표시 (iPhone 연속성, FaceTime 오디오)", "Show incoming and active calls (iPhone Continuity, FaceTime audio)"), isOn: $settings.callEnabled)
            }
            PreviewSection([(.callIncoming, T("수신 전화", "Incoming Call")), (.callActive, T("통화 중", "On a Call"))])
        }
        .settingsForm()
    }
}

struct BatterySettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    private var anyAlertOn: Bool { settings.batteryChargerAlert || settings.batteryFullAlert || settings.batteryLowAlert }

    var body: some View {
        Form {
            SettingsSection(SectionTitle.show) {
                Toggle(T("충전기 연결", "Charger connected"), isOn: $settings.batteryChargerAlert)
                Toggle(T("완충", "Fully charged"), isOn: $settings.batteryFullAlert)
                Toggle(T("배터리 부족", "Low battery"), isOn: $settings.batteryLowAlert)
                Indented(enabled: settings.batteryLowAlert) {
                    ValueSlider(title: T("부족 기준", "Low battery level"), value: $settings.batteryLowThreshold, range: 5...50, step: 5) { "\(Int($0))%" }
                }
            }
            SettingsSection(SectionTitle.live, footer: T("완충됐거나, 충전 한도·배터리 최적화로 충전이 멈춰 전원 어댑터로만 동작하는 동안에는 상시 표시하지 않습니다. 남은 시간은 macOS가 계산한 값이며, 계산 중이면 –로 표시합니다.",
                                                        "Not shown when fully charged, or when charging is paused (charge limit or Optimized Battery Charging) and the Mac runs on the adapter. The time comes from macOS; – means it's still estimating.")) {
                Toggle(T("충전 중 (왼쪽 배터리 %, 오른쪽 완충까지 남은 시간)", "While charging (left: battery %, right: time to full)"), isOn: $settings.batteryChargingPinned)
            }
            SettingsSection(SectionTitle.style, disabled: !anyAlertOn) {
                AlertStylePicker(selection: $settings.batteryStyle)
            }
            PreviewSection([(.charger, T("충전기 연결", "Charger Connected")), (.low, T("배터리 부족", "Low Battery")), (.full, T("완충", "Fully Charged"))])
        }
        .settingsForm()
    }
}

struct HUDSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var hud: HUDStatus
    var openPermissions: () -> Void

    private var anyOn: Bool { settings.hudVolume || settings.hudDisplay || settings.hudKeyboard }

    var body: some View {
        Form {
            SettingsSection(SectionTitle.show) {
                LabeledContent(T("상태", "Status")) {
                    HStack {
                        Text(hud.active ? T("동작 중", "Active") : T("손쉬운 사용 권한 필요", "Accessibility permission needed"))
                            .foregroundStyle(hud.active ? .green : .orange)
                        if !hud.active {
                            Button(T("권한 관리…", "Permissions…"), action: openPermissions)
                        }
                    }
                }
                Toggle(T("음량", "Volume"), isOn: $settings.hudVolume)
                Toggle(T("화면 밝기", "Display brightness"), isOn: $settings.hudDisplay)
                Toggle(T("키보드 밝기", "Keyboard brightness"), isOn: $settings.hudKeyboard)
            }
            SettingsSection(SectionTitle.style, disabled: !anyOn) {
                SegmentedChoice(T("수치 표시", "Value style"), selection: $settings.hudStyle)
                ValueMenu(title: T("표시 시간", "Duration"), selection: $settings.hudDuration, values: [1.0, 1.5, 2.5, 4.0]) {
                    L10n.seconds($0, digits: 1)
                }
            }
            SettingsSection(SectionTitle.details, footer: T("자동 밝기로 바뀐 값은 표시하지 않습니다.", "Changes made by automatic brightness are not shown.")) {
                Toggle(T("음량 HUD에 출력 기기 아이콘 표시", "Show the output device icon in the volume HUD"), isOn: $settings.hudOutputIcon)
                    .disabled(!settings.hudVolume)
                Toggle(T("제어 센터에서 바꾼 화면 밝기도 표시", "Also show display brightness changed in Control Center"), isOn: $settings.hudDisplayExternal)
                    .disabled(!settings.hudDisplay)
                Toggle(T("제어 센터에서 바꾼 키보드 밝기도 표시", "Also show keyboard brightness changed in Control Center"), isOn: $settings.hudKeyboardExternal)
                    .disabled(!settings.hudKeyboard)
            }
            PreviewSection([(.hudVolume, T("음량", "Volume")), (.hudBrightness, T("화면 밝기", "Display Brightness")),
                            (.hudKeyboard, T("키보드 밝기", "Keyboard Brightness"))])
        }
        .settingsForm()
    }
}
