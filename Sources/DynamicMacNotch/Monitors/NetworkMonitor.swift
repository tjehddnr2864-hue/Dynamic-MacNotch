import AppKit
import SwiftUI
import Combine
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
    private static let wakeQuiet: TimeInterval = 3
    /// 잠든 동안 (어두운 깨어남 중의 변화도 알리지 않는다)
    private var asleep = false
    /// 잠들기 전 상태. 깨어난 뒤 첫 알림 판단에서 이것과 비교하고 지운다.
    private var sleepBaseline: State?
    private var pendingEvaluate: DispatchWorkItem?
    private var store: SCDynamicStore?
    private var pinObservers = Set<AnyCancellable>()
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
            let signature = Self.signature(of: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastPath = path
                // AirDrop용 인터페이스처럼 판단에 쓰지 않는 것만 바뀐 경로 갱신은 건너뛴다
                guard signature != self.lastPathSignature else { return }
                self.lastPathSignature = signature
                self.scheduleEvaluate()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.dynamicmacnotch.app.network"))

        // 잠들기 전 상태를 기억해 두고, 잠든 동안과 깨어난 직후 3초는 알리지 않는다 (깨어날 때 끊김·연결이 번갈아 생긴다).
        // 3초가 지나면 잠들기 전과 비교해 네트워크가 달라졌을 때만 알린다 (같은 Wi-Fi에 다시 붙으면 알리지 않음).
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.asleep = true
            if self.sleepBaseline == nil { self.sleepBaseline = self.state }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.asleep = false
            if self.sleepBaseline == nil { self.sleepBaseline = self.state }
            self.quietUntil = Date().addingTimeInterval(Self.wakeQuiet)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeQuiet + 0.2) { [weak self] in self?.evaluate() }
        }
        // VPN 연결·해제는 경로 변화 없이 일어나기도 하므로, 주기 확인 대신 시스템 네트워크 설정 저장소의
        // 변경 알림(SCDynamicStore)을 받는다. 아무 변화가 없으면 아무 일도 하지 않는다.
        observeDynamicStore()

        state = readState()
        applyHotspotPin()
        // 상시 표시 스위치는 바로 반영
        settings.$vpnPinned.merge(with: settings.$hotspotPinned).dropFirst(2)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateVPNCountry()
                self?.applyHotspotPin()
            }
            .store(in: &pinObservers)
        updateVPNCountry()
    }

    // MARK: - VPN 연결 국가 (상시 표시 오른쪽)
    // VPN 앱마다 국가를 알려 주는 공통 방법이 없으므로 공인 IP로 조회한다. 조회도 VPN을 거쳐 나가므로 출구 국가가 나온다.
    // 상시 표시가 켜져 있고 VPN이 연결된 동안에만 조회한다:
    // ① 연결될 때와 네트워크 변경 신호(터널 주소·경로·DNS)가 올 때 곧바로
    // ② 터널 주소가 그대로여서 신호 없이 서버가 바뀌는 VPN을 위해 1분마다.
    // 조회가 실패하면 이전 국가를 그대로 둔다.

    private var vpnCountry: String?
    private var countryWork: DispatchWorkItem?
    private var countryPoll: Timer?
    private var countryToken = 0
    private var lastCountryLookup = Date.distantPast
    /// 신호가 연달아 와도 이 간격보다 자주 조회하지 않는다
    private static let countryMinGap: TimeInterval = 5
    private static let countryPollInterval: TimeInterval = 60

    private func updateVPNCountry() {
        guard settings.vpnPinned, state.vpnName != nil else {
            countryWork?.cancel()
            countryWork = nil
            countryPoll?.invalidate()
            countryPoll = nil
            countryToken &+= 1      // 진행 중인 조회 결과는 버린다
            vpnCountry = nil
            lastCountryLookup = .distantPast
            return
        }
        if countryPoll == nil {
            let t = Timer(timeInterval: Self.countryPollInterval, repeats: true) { [weak self] _ in
                guard let self, self.countryWork == nil else { return }
                self.scheduleCountryLookup(after: 0, retries: [])
            }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            countryPoll = t
        }
        // 경로가 안정되도록 잠깐 모았다가 조회 (새 신호가 오면 다시 기다림)
        countryWork?.cancel()
        let wait = max(1.5, Self.countryMinGap - Date().timeIntervalSince(lastCountryLookup))
        scheduleCountryLookup(after: wait, retries: [4, 10])
    }

    private func scheduleCountryLookup(after delay: TimeInterval, retries: [TimeInterval]) {
        countryToken &+= 1
        let token = countryToken
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.countryToken == token else { return }
            self.lastCountryLookup = Date()
            Self.fetchCountry { [weak self] code in
                guard let self, self.countryToken == token else { return }
                self.countryWork = nil
                if let code {
                    guard code != self.vpnCountry else { return }
                    self.vpnCountry = code
                    self.applyHotspotPin()
                } else if let next = retries.first {
                    self.scheduleCountryLookup(after: next, retries: Array(retries.dropFirst()))
                }
            }
        }
        countryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 공인 IP의 국가 코드 (쿠키·캐시 없이, 첫 서비스가 실패하면 다음 서비스)
    private static func fetchCountry(completion: @escaping (String?) -> Void) {
        #if DEV
        if let debugCountry {
            DispatchQueue.main.async { completion(debugCountry.isEmpty ? nil : debugCountry) }
            return
        }
        #endif
        let services: [(URL, (Data) -> String?)] = [
            (URL(string: "https://api.country.is/")!, { data in
                (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["country"] as? String
            }),
            (URL(string: "https://ipinfo.io/country")!, { String(data: $0, encoding: .utf8) }),
        ]
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        func attempt(_ index: Int) {
            guard index < services.count else {
                session.finishTasksAndInvalidate()
                DispatchQueue.main.async { completion(nil) }
                return
            }
            session.dataTask(with: services[index].0) { data, response, _ in
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                let raw = ok ? data.flatMap(services[index].1) : nil
                let code = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                // 응답을 믿지 않고 형식을 확인한다 (영문 2~3글자만 노치에 표시)
                if let code, (2...3).contains(code.count), code.allSatisfy({ $0.isASCII && $0.isLetter }) {
                    session.finishTasksAndInvalidate()
                    DispatchQueue.main.async { completion(code) }
                } else {
                    attempt(index + 1)
                }
            }.resume()
        }
        attempt(0)
    }

    #if DEV
    /// 개발용: VPN 연결·해제를 흉내 낸다 (이름, nil이면 실제 상태)
    static var debugVPNName: String?
    /// 개발용: 국가 조회 결과를 정한다 (빈 문자열이면 조회 실패, nil이면 실제 조회)
    static var debugCountry: String?
    func debugEvaluate() { evaluate() }
    static var debugLog: [String] = []
    #endif

    private func observeDynamicStore() {
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                        retain: nil, release: nil, copyDescription: nil)
        guard let s = SCDynamicStoreCreate(nil, "DynamicMacNotch" as CFString, { _, keys, info in
            guard let info else { return }
            // 바뀐 키가 모두 무관한 인터페이스면 다시 읽지 않는다 (awdl0·llw0은 십여 초마다 바뀐다)
            if let keys = keys as? [String], !keys.isEmpty, keys.allSatisfy(NetworkMonitor.isNoise(key:)) { return }
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

    // MARK: - 무관한 변화 거르기

    private var lastPathSignature = ""

    /// Wi-Fi·VPN·핫스팟 판단과 무관한 인터페이스: AirDrop·AirPlay(awdl, llw), 내부용(anpi, ap), 루프백 등
    static func isNoise(interface name: String) -> Bool {
        name.range(of: #"^(awdl|llw|anpi|ap|lo|gif|stf)\d+$"#, options: .regularExpression) != nil
    }

    /// 시스템 네트워크 저장소 키가 무관한 인터페이스의 것인지 (예: State:/Network/Interface/awdl0/IPv6)
    static func isNoise(key: String) -> Bool {
        let parts = key.split(separator: "/")
        guard parts.count >= 4, parts[1] == "Network", parts[2] == "Interface" else { return false }
        return isNoise(interface: String(parts[3]))
    }

    /// readState가 경로에서 쓰는 값만 모은 것. 이것이 같으면 판단 결과도 같다.
    private static func signature(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces.filter { !isNoise(interface: $0.name) }.map { "\($0.name):\($0.type)" }
        return "\(path.status)|\(path.isExpensive)|\(path.usesInterfaceType(.wifi))|\(interfaces.joined(separator: ","))"
    }

    // MARK: - CWEventDelegate (백그라운드 스레드에서 호출됨)

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { scheduleEventFromAnyThread() }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { scheduleEventFromAnyThread() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { scheduleEventFromAnyThread() }

    private func scheduleEventFromAnyThread() {
        DispatchQueue.main.async { self.scheduleEvaluate() }
    }

    /// 여러 이벤트가 연달아 오므로 0.6초 모아서 한 번 판단한다.
    /// Wi-Fi가 붙는 순간에는 Wi-Fi 정보(채널·이름)와 경로가 서로 다른 때에 갖춰져, 마지막 신호 때에도 아직 '연결 안 됨'으로
    /// 읽힐 수 있다. 그래서 신호가 멎은 뒤 두 번 더 확인한다 (예전에는 십여 초마다 오던 AirDrop 신호가 우연히 이 역할을 했다).
    private func scheduleEvaluate() {
        pendingEvaluate?.cancel()
        followUps.forEach { $0.cancel() }
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pendingEvaluate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        followUps = Self.followUpDelays.map { delay in
            let item = DispatchWorkItem { [weak self] in self?.evaluate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }
    private var followUps: [DispatchWorkItem] = []
    private static let followUpDelays: [TimeInterval] = [2.5, 6]

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
        #if DEV
        if let debugVPNName { return debugVPNName.isEmpty ? nil : debugVPNName }
        #endif
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
        #if DEV
        // 개발용: 판단 기록 (네트워크 이름은 남기지 않는다)
        Self.debugLog.append("\(Date().timeIntervalSince1970) on=\(new.wifiOn) linked=\(new.wifiLinked) ssid=\(new.ssid != nil) "
            + "channel=\(client.interface()?.wlanChannel() != nil) pathWifi=\(lastPath?.availableInterfaces.contains { $0.type == .wifi } ?? false) "
            + "online=\(new.online) vpn=\(new.vpnName != nil) changed=\(new != old) quiet=\(Date() < quietUntil)")
        if Self.debugLog.count > 60 { Self.debugLog.removeFirst(Self.debugLog.count - 60) }
        #endif
        // 네트워크 변경 신호마다: VPN이 바뀌면 이전 국가를 지우고, 연결된 채면 서버가 바뀌었을 수 있으니 다시 조회
        if new.vpnName != old.vpnName { vpnCountry = nil }
        updateVPNCountry()
        applyHotspotPin()
        // 잠든 동안·깨어난 직후에는 상태만 따라가고 알리지 않는다
        guard !asleep, Date() >= quietUntil else { return }
        let before = sleepBaseline ?? old
        sleepBaseline = nil
        guard new != before else { return }

        // 쓰던 네트워크가 중간에 끊겨 연결된 네트워크가 하나도 없으면 상세 팝업으로 알린다.
        // (사용자가 Wi-Fi를 직접 끈 경우는 'Wi-Fi 꺼짐'으로 알리므로 제외, 잠깐 끊겼다 붙는 경우는 2초 뒤 다시 확인)
        if before.online, !new.online, new.wifiOn == before.wifiOn {
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

        if new.wifiOn != before.wifiOn {
            if settings.netWifiPower {
                post(symbol: new.wifiOn ? "wifi" : "wifi.slash", tint: new.wifiOn ? .blue : .gray,
                     short: new.wifiOn ? T("켜짐", "On") : T("꺼짐", "Off"), title: "Wi-Fi", detail: new.wifiOn ? T("Wi-Fi 켜짐", "Wi-Fi On") : T("Wi-Fi 꺼짐", "Wi-Fi Off"))
            }
            return   // 전원 변화에 딸린 연결/해제는 따로 알리지 않는다
        }

        if new.hotspot != before.hotspot, settings.netHotspot {
            post(symbol: "personalhotspot", tint: new.hotspot ? .green : .gray,
                 short: new.hotspot ? T("연결됨", "Connected") : T("해제됨", "Disconnected"), title: T("개인용 핫스팟", "Personal Hotspot"),
                 detail: new.hotspot ? (new.ssid ?? T("연결됨", "Connected")) : T("연결 해제됨", "Disconnected"))
        } else if (new.wifiLinked != before.wifiLinked || (new.wifiLinked && new.ssid != before.ssid)), settings.netWifiConnection {
            if new.wifiLinked {
                post(symbol: "wifi", tint: .blue, short: T("연결됨", "Connected"), title: "Wi-Fi", detail: new.ssid ?? T("연결됨", "Connected"))
            } else {
                post(symbol: "wifi.exclamationmark", tint: .gray, short: T("해제됨", "Disconnected"), title: "Wi-Fi", detail: T("연결 해제됨", "Disconnected"))
            }
        }

        if new.vpnName != before.vpnName, settings.netVPN {
            if let name = new.vpnName {
                post(symbol: "network", tint: .blue, short: T("연결됨", "Connected"), title: "VPN", detail: name)
            } else {
                post(symbol: "network", tint: .gray, short: T("해제됨", "Disconnected"), title: "VPN", detail: T("연결 해제됨", "Disconnected"))
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

    /// 국가 코드 → 앱 언어로 쓴 국가 이름 (길게 눌러 여는 화면용)
    private static func countryName(_ code: String) -> String {
        Locale(identifier: T("ko", "en")).localizedString(forRegionCode: code) ?? code
    }

    /// 텍스트 길이에 맞춰 노치 옆 날개 폭을 늘린다 (60~130pt).
    static func wing(for text: String) -> CGFloat {
        let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width
        return min(130, max(60, width + 22))
    }

    /// 핫스팟 '연결 중 상시 표시' 옵션.
    private func applyHotspotPin() {
        // VPN 상시 표시도 같이: 연결 순간의 알림에만 '연결됨', 계속 표시하는 동안은 왼쪽 아이콘만
        if settings.vpnPinned, let name = state.vpnName {
            center.setPersistent(NotchActivity(
                kind: .vpn, priority: ActivityPriority.pinned, symbol: "network", tint: .blue,
                value: vpnCountry.map { .text($0) } ?? .none,     // 오른쪽: 연결된 국가 코드 (모르면 비움)
                title: "VPN", subtitle: vpnCountry.map { "\(name) · \(Self.countryName($0))" } ?? name,
                detailValue: .text(T("연결됨", "Connected")), wing: NotchActivity.compactWing))
        } else {
            center.removePersistent(.vpn)
        }
        if settings.hotspotPinned, state.hotspot {
            center.setPersistent(NotchActivity(
                kind: .hotspot, priority: ActivityPriority.pinned,
                // 연결 순간의 알림에만 '연결됨'을 보이고, 계속 표시하는 동안은 아이콘만 (집중 모드와 같음).
                // 길게 눌러 여는 화면에는 '연결됨'을 보여 준다.
                symbol: "personalhotspot", tint: .green,
                value: .none, title: T("개인용 핫스팟", "Personal Hotspot"), subtitle: state.ssid,
                detailValue: .text(T("연결됨", "Connected"))
            ))
        } else {
            center.removePersistent(.hotspot)
        }
    }
}
