import AppKit
import WebKit

/// 웹 로그인·사용량 조회 (WebKit). 본 앱에서는 쓰지 않고, 도우미 프로세스(조회)와 설정 창(로그인)에서만 쓴다.
/// 로그인 정보(쿠키)는 이 앱 전용 웹 저장소(WKWebsiteDataStore.default)에만 남고, 앱이 따로 보관하거나 보내지 않는다.
enum UsageWeb {
    /// Google 등은 앱 안 웹 화면의 로그인을 막으므로 Safari와 같은 이름으로 접속한다
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    static func services(from arguments: [String]) -> [AIService]? {
        guard let arg = arguments.first(where: { $0.hasPrefix("--usage-fetch=") }) else { return nil }
        return arg.dropFirst("--usage-fetch=".count).split(separator: ",").compactMap { AIService(rawValue: String($0)) }
    }

    static func makeWebView(frame: NSRect = NSRect(x: 0, y: 0, width: 900, height: 700)) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: frame, configuration: config)
        web.customUserAgent = userAgent
        return web
    }

    /// 로그아웃: 해당 서비스 도메인의 웹 데이터(쿠키 등)를 지운다
    static func signOut(_ service: AIService, completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let targets = records.filter { r in service.dataDomains.contains { r.displayName.contains($0) } }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: targets, completionHandler: completion)
        }
    }
}

// MARK: - 사용량 조회 도우미 (`--usage-fetch=claude,chatgpt,gemini`)

/// 서비스마다 웹 화면을 하나 열어(보이지 않게) 로그인된 상태로 사용량을 읽고, JSON으로 출력한 뒤 끝난다.
final class UsageFetchDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var queue: [AIService]
    private var results: [String: ServiceUsage] = [:]
    private var current: AIService?
    private var window: NSWindow?
    private var web: WKWebView?
    private var timeout: DispatchWorkItem?
    private var finishedCurrent = false

    init(services: [AIService]) {
        queue = services
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 화면 밖·숨김 창이면 웹 페이지가 그리기를 멈춰 Gemini 같은 앱형 페이지가 내용을 채우지 않는다.
        // 투명하고 클릭이 통과하는 창을 띄워 '보이는 상태'로 둔다.
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window = w
        // 전체 한도: 무슨 일이 있어도 90초 안에 끝낸다
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in self?.finish() }
        next()
    }

    private func next() {
        timeout?.cancel()
        web?.navigationDelegate = nil
        web?.stopLoading()
        web?.removeFromSuperview()
        web = nil
        guard !queue.isEmpty else { finish(); return }
        let service = queue.removeFirst()
        current = service
        finishedCurrent = false
        scriptTries = 0
        // 로그인 쿠키가 없으면 페이지를 열지 않고 바로 '로그인 필요'
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            guard cookies.contains(where: { service.isSessionCookie(domain: $0.domain, name: $0.name) }) else {
                self.complete(service, error: "login")
                return
            }
            let view = UsageWeb.makeWebView()
            view.navigationDelegate = self
            self.window?.contentView = view
            self.window?.orderFrontRegardless()
            self.web = view
            let work = DispatchWorkItem { [weak self] in self?.complete(service, error: "timeout") }
            self.timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
            view.load(URLRequest(url: Self.startURL(service)))
        }
    }

    private static func startURL(_ s: AIService) -> URL {
        switch s {
        case .claude: return URL(string: "https://claude.ai/api/organizations")!
        case .chatgpt: return URL(string: "https://chatgpt.com/api/auth/session")!
        case .gemini: return URL(string: "https://gemini.google.com/usage")!
        }
    }

    private func complete(_ service: AIService, usage: ServiceUsage? = nil, error: String? = nil) {
        guard current == service, !finishedCurrent else { return }
        finishedCurrent = true
        results[service.rawValue] = usage ?? ServiceUsage(fetched: Date(), error: error ?? "parse")
        next()
    }

    private func finish() {
        let data = (try? JSONEncoder().encode(results)) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data)
        exit(0)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let service = current, webView === web, !finishedCurrent else { return }
        if webView.url?.host?.contains("accounts.google.com") == true || webView.url?.path.contains("/login") == true {
            complete(service, error: "login")
            return
        }
        switch service {
        case .claude: runScript(Self.claudeScript, service: service, parse: UsageParser.claude)
        case .chatgpt: runScript(Self.chatgptScript, service: service, parse: UsageParser.chatgpt)
        case .gemini: readGemini(attempt: 0)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let s = current, webView === web { complete(s, error: "network") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let s = current, webView === web { complete(s, error: "network") }
    }

    private var scriptTries = 0

    private func runScript(_ js: String, service: AIService, parse: @escaping (Data) -> ServiceUsage?) {
        web?.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, self.current == service else { return }
            guard case .success(let value) = result, let text = value as? String else {
                self.complete(service, error: "network")
                return
            }
            let data = Data(text.utf8)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let err = obj["error"] as? String {
                // 보안 확인 페이지(Cloudflare)를 지나는 중이면 잠시 뒤 한 번 더
                if err.hasPrefix("http 403"), self.scriptTries == 0 {
                    self.scriptTries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.runScript(js, service: service, parse: parse) }
                    return
                }
                // 다시 해도 거부(403)면 로그인이 풀린 것으로 본다
                self.complete(service, error: err == "login" || err.hasPrefix("http 403") ? "login" : "network")
                return
            }
            if let usage = parse(data) { self.complete(service, usage: usage) } else { self.complete(service, error: "nodata") }
        }
    }

    /// Gemini 사용량 페이지는 화면이 그려진 뒤에야 숫자가 나오므로 1초마다 글자를 읽어 본다 (최대 20초)
    private func readGemini(attempt: Int) {
        web?.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] value, _ in
            guard let self, self.current == .gemini, !self.finishedCurrent else { return }
            if let text = value as? String, let usage = UsageParser.gemini(text) {
                self.complete(.gemini, usage: usage)
            } else if attempt >= 20 {
                self.complete(.gemini, error: "parse")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.readGemini(attempt: attempt + 1) }
            }
        }
    }

    private static let claudeScript = """
    const r = await fetch('/api/organizations', {credentials: 'include'});
    if (r.status === 401) return JSON.stringify({error: 'login'});
    if (!r.ok) return JSON.stringify({error: 'http ' + r.status});
    const orgs = await r.json();
    if (!Array.isArray(orgs) || orgs.length === 0) return JSON.stringify({error: 'login'});
    const org = orgs.find(o => (o.capabilities || []).includes('chat')) || orgs[0];
    const u = await fetch('/api/organizations/' + org.uuid + '/usage', {credentials: 'include'});
    if (!u.ok) return JSON.stringify({error: 'http ' + u.status});
    return await u.text();
    """

    private static let chatgptScript = """
    let s = {};
    try { s = await (await fetch('/api/auth/session', {credentials: 'include'})).json(); } catch (e) {}
    if (!s || !s.accessToken) return JSON.stringify({error: 'login'});
    const h = {Authorization: 'Bearer ' + s.accessToken};
    if (s.account && s.account.id) h['ChatGPT-Account-Id'] = s.account.id;
    const r = await fetch('/backend-api/wham/usage', {headers: h, credentials: 'include'});
    if (r.status === 401) return JSON.stringify({error: 'login'});
    if (!r.ok) return JSON.stringify({error: 'http ' + r.status});
    return await r.text();
    """
}

// MARK: - 응답 읽기

enum UsageParser {
    /// claude.ai: {"five_hour": {"utilization": 42, "resets_at": "..."}, "seven_day": {...}}
    static func claude(_ data: Data) -> ServiceUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String, _ seconds: Double) -> UsageWindow? {
            guard let w = obj[key] as? [String: Any], let u = number(w["utilization"]) else { return nil }
            return UsageWindow(percent: min(100, max(0, u)), resetsAt: (w["resets_at"] as? String).flatMap(date), seconds: seconds)
        }
        let usage = ServiceUsage(windows: [window("five_hour", UsageWindow.fiveHours), window("seven_day", UsageWindow.week)].compactMap { $0 },
                                 fetched: Date())
        return usage.hasData ? usage : nil
    }

    /// chatgpt.com(Codex 한도): rate_limit.primary_window / secondary_window
    /// {"used_percent": 12, "limit_window_seconds": 18000, "reset_at": 1730000000 | "reset_after_seconds": 3600}
    /// 유료는 5시간·주간, 무료는 30일 한도 하나만 오는 식이라 기간을 그대로 담는다.
    static func chatgpt(_ data: Data) -> ServiceUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var windows: [UsageWindow] = []
        func visit(_ any: Any) {
            if let d = any as? [String: Any] {
                if let used = number(d["used_percent"]) {
                    let seconds = number(d["limit_window_seconds"]) ?? 0
                    var reset: Date?
                    if let at = number(d["reset_at"]) { reset = Date(timeIntervalSince1970: at) }
                    else if let after = number(d["reset_after_seconds"]) { reset = Date().addingTimeInterval(after) }
                    if seconds > 0 {
                        windows.append(UsageWindow(percent: min(100, max(0, used)), resetsAt: reset, seconds: seconds))
                    }
                }
                d.values.forEach(visit)
            } else if let a = any as? [Any] {
                a.forEach(visit)
            }
        }
        visit(obj)
        let usage = ServiceUsage(windows: windows, fetched: Date())
        return usage.hasData ? usage : nil
    }

    /// gemini.google.com/usage 화면 글자에서 한도(5시간·일일·주간·월간)를 찾는다.
    /// 퍼센트(42%)나 개수(12 / 100) 앞뒤 몇 줄 안에 기간을 나타내는 말이 있으면 그 한도로 본다.
    /// '남음/remaining/left'이면 사용량 = 100 - 값.
    static func gemini(_ text: String) -> ServiceUsage? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var windows: [UsageWindow] = []
        // 기간 이름 → 길이(초). 앞의 것부터 확인한다.
        let periods: [([String], Double)] = [
            (["5시간", "5 시간", "5 hour", "5-hour", "5h"], UsageWindow.fiveHours),
            (["일일", "매일", "하루", "24시간", "daily", "per day", "24 hour", "24-hour"], 86400),
            (["주간", "매주", "week", "7일", "7 day"], UsageWindow.week),
            (["월간", "매월", "30일", "month", "30 day", "30-day"], 30 * 86400),
        ]
        let percentRe = try! NSRegularExpression(pattern: #"(\d{1,3}(?:[.,]\d+)?)\s*%"#)
        let countRe = try! NSRegularExpression(pattern: #"(\d+)\s*(?:/|of|중)\s*(\d+)"#)
        for (i, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            var value: Double?
            if let m = percentRe.firstMatch(in: line, range: range), let r = Range(m.range(at: 1), in: line) {
                value = Double(line[r].replacingOccurrences(of: ",", with: "."))
            } else if let m = countRe.firstMatch(in: line, range: range),
                      let a = Range(m.range(at: 1), in: line), let b = Range(m.range(at: 2), in: line),
                      let used = Double(line[a]), let total = Double(line[b]), total > 0 {
                value = used / total * 100
            }
            guard var v = value, v <= 100 else { continue }
            let context = lines[max(0, i - 3)...min(lines.count - 1, i + 1)].joined(separator: " ").lowercased()
            if ["남음", "남은", "remaining", "left"].contains(where: context.contains) { v = 100 - v }
            if let period = periods.first(where: { $0.0.contains(where: context.contains) }),
               !windows.contains(where: { $0.seconds == period.1 }) {
                windows.append(UsageWindow(percent: v, resetsAt: nil, seconds: period.1))
            }
        }
        let usage = ServiceUsage(windows: windows, fetched: Date())
        return usage.hasData ? usage : nil
    }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - 로그인 창 (설정 창 도우미에서 연다)

/// 서비스 웹 로그인 화면. 로그인 쿠키가 생기면 '연결됨'으로 기록하고 닫힌다.
final class UsageLoginWindow: NSObject, NSWindowDelegate {
    private static var open: [AIService: UsageLoginWindow] = [:]

    private let service: AIService
    private let window: NSWindow
    private let web: WKWebView
    private var timer: Timer?

    static func show(_ service: AIService) {
        if let existing = open[service] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let w = UsageLoginWindow(service: service)
        open[service] = w
        w.window.center()
        w.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(service: AIService) {
        self.service = service
        web = UsageWeb.makeWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 700))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = T("\(service.name) 로그인", "Sign in to \(service.name)")
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.delegate = self
        web.load(URLRequest(url: service.loginURL))
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkLogin() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkLogin() {
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, cookies.contains(where: { self.service.isSessionCookie(domain: $0.domain, name: $0.name) }) else { return }
            self.timer?.invalidate()
            let settings = AppSettings.shared
            var list = AppSettings.list(settings.aiConnected)
            if !list.contains(self.service.rawValue) { list.append(self.service.rawValue) }
            settings.aiConnected = list.joined(separator: ",")
            // 로그인 후 이어지는 이동이 끝나도록 잠깐 뒤 닫는다
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.window.close() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        web.stopLoading()
        Self.open[service] = nil
    }
}
