import AppKit
import SwiftUI
import CoreWLAN
import Network
import SystemConfiguration

/// 네트워크 상태 변화 감지 (가이드라인 5.3): Wi-Fi 전원, Wi-Fi 연결, VPN, 핫스팟.
/// 좌: 아이콘, 우: 상태 텍스트로 잠깐 표시한다.
final class NetworkMonitor: NSObject, CWEventDelegate {
    private struct State: Equatable {
        var wifiOn = false
        var ssid: String?
        var wifiLinked = false
        var vpnName: String?
        var hotspot = false
        /// 인터넷에 나갈 수 있는 경로가 있는지 (Wi-Fi·유선·핫스팟 무엇이든)
        var online = true
    }

    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private let client = CWWiFiClient.shared()
    private let pathMonitor = NWPathMonitor()
    private var lastPath: NWPath?
    private var state = State()
    private var quietUntil = Date().addingTimeInterval(2)   // 시작 직후 초기 상태는 알리지 않는다
    private var pendingEvaluate: DispatchWorkItem?
    private var store: SCDynamicStore?
    private var offlineCheck: DispatchWorkItem?

    init(center: ActivityCenter) {
        self.center = center
        super.init()
    }

    func start() {
        client.delegate = self
        for event in [CWEventType.powerDidChange, .ssidDidChange, .linkDidChange] {
            try? client.startMonitoringEvent(with: event)
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.lastPath = path
                self?.scheduleEvaluate()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.dynamicmacnotch.app.network"))

        // 잠자기 해제 직후 3초간은 연결/해제 알림을 무시한다.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.quietUntil = Date().addingTimeInterval(3)
        }
        // VPN 연결·해제는 경로 변화 없이 일어나기도 하므로, 주기 확인 대신 시스템 네트워크 설정 저장소의
        // 변경 알림(SCDynamicStore)을 받는다. 아무 변화가 없으면 아무 일도 하지 않는다.
        observeDynamicStore()

        state = readState()
        applyHotspotPin()
    }

    private func observeDynamicStore() {
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                        retain: nil, release: nil, copyDescription: nil)
        guard let s = SCDynamicStoreCreate(nil, "DynamicMacNotch" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue().scheduleEvaluate()
        }, &ctx) else { return }
        let patterns = [
            "State:/Network/Global/.*",            // 기본 경로·프록시(VPN 범위 지정 포함)
            "State:/Network/Service/.*/IPv4",       // 서비스 연결/해제
            "State:/Network/Service/.*/PPP",
            "State:/Network/Service/.*/IPSec",
            "State:/Network/Interface/.*/IPv4",     // utun 등 VPN 인터페이스
            "State:/Network/Interface/.*/IPv6",
            "State:/Network/Interface",             // 인터페이스 목록(터널 생성·삭제)
        ] as CFArray
        SCDynamicStoreSetNotificationKeys(s, nil, patterns)
        SCDynamicStoreSetDispatchQueue(s, .main)
        store = s
    }

    // MARK: - CWEventDelegate (백그라운드 스레드에서 호출됨)

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { scheduleEventFromAnyThread() }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { scheduleEventFromAnyThread() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { scheduleEventFromAnyThread() }

    private func scheduleEventFromAnyThread() {
        DispatchQueue.main.async { self.scheduleEvaluate() }
    }

    /// 여러 이벤트가 연달아 오므로 0.6초 모아서 한 번 판단한다.
    private func scheduleEvaluate() {
        pendingEvaluate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pendingEvaluate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - 상태 읽기

    private func readState() -> State {
        var s = State()
        let iface = client.interface()
        s.wifiOn = iface?.powerOn() ?? false
        s.ssid = iface?.ssid()
        let wifiPathUp = lastPath?.availableInterfaces.contains { $0.type == .wifi } ?? false
        s.wifiLinked = s.wifiOn && (s.ssid != nil || (iface?.wlanChannel() != nil && wifiPathUp))
        s.vpnName = Self.activeVPNName()
        let pinned = AppSettings.list(settings.hotspotSSIDs)
        let byList = s.ssid.map { pinned.contains($0) } ?? false
        let expensiveWifi = (lastPath?.isExpensive ?? false) && (lastPath?.usesInterfaceType(.wifi) ?? false)
        s.hotspot = s.wifiLinked && (byList || expensiveWifi)
        s.online = (lastPath?.status ?? .satisfied) == .satisfied
        return s
    }

    /// 연결된 VPN 이름. 시스템 설정의 VPN 서비스를 먼저 보고, 없으면 VPN 인터페이스 존재로 판단한다.
    static func activeVPNName() -> String? {
        if let prefs = SCPreferencesCreate(nil, "DynamicMacNotch" as CFString, nil),
           let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
            for service in services where SCNetworkServiceGetEnabled(service) {
                guard let iface = SCNetworkServiceGetInterface(service),
                      let type = SCNetworkInterfaceGetInterfaceType(iface) as String?,
                      [kSCNetworkInterfaceTypePPP as String, kSCNetworkInterfaceTypeIPSec as String, "VPN"].contains(type),
                      let id = SCNetworkServiceGetServiceID(service),
                      let conn = SCNetworkConnectionCreateWithServiceID(nil, id, nil, nil) else { continue }
                if SCNetworkConnectionGetStatus(conn) == .connected {
                    return (SCNetworkServiceGetName(service) as String?) ?? "VPN"
                }
            }
        }
        // VPN 앱(NordVPN 등)이 만든 터널: utun 같은 터널 인터페이스에 실제 주소(IPv4 또는 링크 로컬이 아닌 IPv6)가 붙는다.
        // 시스템이 늘 만들어 두는 utun은 링크 로컬(fe80::) 주소만 있어 걸러진다.
        if hasAddressedTunnel() { return runningVPNAppName() ?? "VPN" }
        // 네트워크 확장 기반 VPN 앱: 범위 지정 프록시 목록에 VPN 인터페이스가 나타난다.
        if let proxies = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
           let scoped = proxies["__SCOPED__"] as? [String: Any] {
            let vpnPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]
            if scoped.keys.contains(where: { key in vpnPrefixes.contains { key.hasPrefix($0) } }) {
                return "VPN"
            }
        }
        return nil
    }

    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]

    /// 실제 주소가 붙은 터널 인터페이스가 있는지 (getifaddrs, 시스템 호출 한 번)
    static func hasAddressedTunnel() -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }
        var found = false
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let ifa = cur.pointee
            let name = String(cString: ifa.ifa_name)
            guard tunnelPrefixes.contains(where: { name.hasPrefix($0) }),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  let addr = ifa.ifa_addr else { continue }
            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                found = true
            case AF_INET6:
                let linkLocal = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a in
                    a.pointee.sin6_addr.__u6_addr.__u6_addr8.0 == 0xfe && (a.pointee.sin6_addr.__u6_addr.__u6_addr8.1 & 0xc0) == 0x80
                }
                if !linkLocal { found = true }
            default:
                break
            }
            if found { break }
        }
        return found
    }

    /// 실행 중인 VPN 앱 이름 (알림에 'NordVPN'처럼 표시)
    private static func runningVPNAppName() -> String? {
        let known = ["vpn", "wireguard", "tailscale", "mullvad", "warp", "tunnelblick", "outline", "zerotier", "openvpn"]
        return NSWorkspace.shared.runningApplications.first { app in
            let name = (app.localizedName ?? "").lowercased()
            return known.contains { name.contains($0) }
        }?.localizedName
    }

    // MARK: - 판단

    private func evaluate() {
        let old = state
        let new = readState()
        state = new
        applyHotspotPin()
        guard new != old, Date() >= quietUntil else { return }

        // 쓰던 네트워크가 중간에 끊겨 연결된 네트워크가 하나도 없으면 상세 팝업으로 알린다.
        // (사용자가 Wi-Fi를 직접 끈 경우는 'Wi-Fi 꺼짐'으로 알리므로 제외, 잠깐 끊겼다 붙는 경우는 2초 뒤 다시 확인)
        if old.online, !new.online, new.wifiOn == old.wifiOn {
            offlineCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.state.online, self.settings.netWifiConnection else { return }
                self.center.post(NotchActivity(
                    kind: .network, presentation: .detail, duration: 4,
                    symbol: "antenna.radiowaves.left.and.right.slash", tint: .orange,
                    value: .text(T("없음", "None")), title: T("연결된 네트워크 없음", "No Network Connection"),
                    subtitle: T("Wi-Fi·셀룰러 연결이 끊겼습니다", "Wi-Fi and cellular are disconnected")
                ))
            }
            offlineCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            return
        }
        if new.online { offlineCheck?.cancel() }

        if new.wifiOn != old.wifiOn {
            if settings.netWifiPower {
                post(symbol: new.wifiOn ? "wifi" : "wifi.slash", tint: new.wifiOn ? .blue : .gray,
                     short: new.wifiOn ? T("켜짐", "On") : T("꺼짐", "Off"), title: "Wi-Fi", detail: new.wifiOn ? T("Wi-Fi 켜짐", "Wi-Fi On") : T("Wi-Fi 꺼짐", "Wi-Fi Off"))
            }
            return   // 전원 변화에 딸린 연결/해제는 따로 알리지 않는다
        }

        if new.hotspot != old.hotspot, settings.netHotspot {
            post(symbol: "personalhotspot", tint: new.hotspot ? .green : .gray,
                 short: new.hotspot ? T("연결됨", "Connected") : T("해제됨", "Disconnected"), title: T("개인용 핫스팟", "Personal Hotspot"),
                 detail: new.hotspot ? (new.ssid ?? T("연결됨", "Connected")) : T("연결 해제됨", "Disconnected"))
        } else if (new.wifiLinked != old.wifiLinked || (new.wifiLinked && new.ssid != old.ssid)), settings.netWifiConnection {
            if new.wifiLinked {
                post(symbol: "wifi", tint: .blue, short: T("연결됨", "Connected"), title: "Wi-Fi", detail: new.ssid ?? T("연결됨", "Connected"))
            } else {
                post(symbol: "wifi.exclamationmark", tint: .gray, short: T("해제됨", "Disconnected"), title: "Wi-Fi", detail: T("연결 해제됨", "Disconnected"))
            }
        }

        if new.vpnName != old.vpnName, settings.netVPN {
            if let name = new.vpnName {
                post(symbol: "lock.shield.fill", tint: .green, short: T("연결됨", "Connected"), title: "VPN", detail: name)
            } else {
                post(symbol: "lock.open", tint: .gray, short: T("해제됨", "Disconnected"), title: "VPN", detail: T("연결 해제됨", "Disconnected"))
            }
        }
    }

    /// 컴팩트: 아이콘 + 짧은 단어(켜짐/꺼짐/연결됨/해제됨)만.
    /// 상세: 좌우·아래로 커진 카드에 이름(Wi-Fi 이름, VPN 이름 등)까지.
    private func post(symbol: String, tint: Color, short: String, title: String, detail: String) {
        let detailed = settings.netStyle == .detail
        center.post(NotchActivity(
            kind: .network,
            presentation: detailed ? .detail : .compact,
            duration: AppSettings.duration(settings.netDuration),
            symbol: symbol,
            tint: tint,
            value: .text(short),
            title: title,
            subtitle: detail,
            wing: Self.wing(for: short)
        ))
    }

    /// 텍스트 길이에 맞춰 노치 옆 날개 폭을 늘린다 (60~130pt).
    static func wing(for text: String) -> CGFloat {
        let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width
        return min(130, max(60, width + 22))
    }

    /// 핫스팟 '연결 중 상시 표시' 옵션.
    private func applyHotspotPin() {
        if settings.hotspotPinned, state.hotspot {
            center.setPersistent(NotchActivity(
                kind: .hotspot, priority: ActivityPriority.pinned,
                symbol: "personalhotspot", tint: .green,
                value: .text(T("연결됨", "Connected")), title: T("개인용 핫스팟", "Personal Hotspot"), subtitle: state.ssid,
                wing: Self.wing(for: T("연결됨", "Connected"))
            ))
        } else {
            center.removePersistent(.hotspot)
        }
    }
}
