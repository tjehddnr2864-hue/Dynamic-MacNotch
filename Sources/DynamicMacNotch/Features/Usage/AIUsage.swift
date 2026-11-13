import AppKit
import Combine
import SwiftUI

/// 사용량을 보여 줄 AI 서비스 (웹에 로그인해 연동)
enum AIService: String, CaseIterable, Identifiable, Codable {
    case claude, chatgpt, gemini

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .gemini: return "Gemini"
        }
    }

    /// 노치 안 짧은 이름
    var shortName: String { self == .chatgpt ? "GPT" : name }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .chatgpt: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .gemini: return Color(red: 0.36, green: 0.55, blue: 0.98)
        }
    }

    /// 로그인 창에서 여는 주소
    var loginURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/login")!
        case .chatgpt: return URL(string: "https://chatgpt.com/auth/login")!
        case .gemini: return URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fgemini.google.com%2Fusage")!
        }
    }

    /// 사용량을 직접 확인하는 웹 페이지 (노치에서 '열기')
    var usagePageURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .chatgpt: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .gemini: return URL(string: "https://gemini.google.com/usage")!
        }
    }

    /// 로그아웃할 때 지울 웹 데이터의 도메인
    var dataDomains: [String] {
        switch self {
        case .claude: return ["claude.ai", "anthropic.com"]
        case .chatgpt: return ["chatgpt.com", "openai.com"]
        case .gemini: return ["google.com", "gemini.google.com", "gstatic.com"]
        }
    }

    /// 로그인했는지 판단하는 쿠키 (도메인 일부, 이름 앞부분)
    func isSessionCookie(domain: String, name: String) -> Bool {
        switch self {
        case .claude: return domain.contains("claude.ai") && name == "sessionKey"
        case .chatgpt: return domain.contains("chatgpt.com") && name.hasPrefix("__Secure-next-auth.session-token")
        case .gemini: return domain.contains("google.com") && (name == "__Secure-1PSID" || name == "SID")
        }
    }

    static func connected(_ csv: String) -> [AIService] {
        let set = Set(AppSettings.list(csv))
        return allCases.filter { set.contains($0.rawValue) }
    }
}

/// 한 기간(5시간·주간·30일 등)의 사용량
struct UsageWindow: Codable, Equatable {
    /// 사용한 비율 0~100
    var percent: Double
    var resetsAt: Date?
    /// 한도 기간 (초) — 5시간 18000, 주간 604800, 30일 2592000
    var seconds: Double
    /// 모델·기능 하나에만 걸린 한도의 이름 (예: Claude의 "Fable" 주간 한도). 전체 한도면 nil.
    var name: String?

    static let fiveHours: Double = 5 * 3600
    static let week: Double = 7 * 86400

    init(percent: Double, resetsAt: Date?, seconds: Double, name: String? = nil) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.seconds = seconds
        self.name = name
    }

    /// 설정에 저장하는 이름 (5h · 168h · 168h:fable). 기간과 이름이 같으면 같은 한도다.
    var id: String { "\(Int((seconds / 3600).rounded()))h" + (name.map { ":" + $0.lowercased() } ?? "") }

    /// 노치 안 짧은 이름 (5h · wk · 30d · Fable)
    var shortLabel: String {
        if let name { return name.count <= 5 ? name : String(name.prefix(4)) }
        return periodShort
    }

    /// 화면의 이름 (5시간 · 주간 · 30일 · Fable 주간)
    var label: String {
        name.map { "\($0) \(periodLabel)" } ?? periodLabel
    }

    private var periodShort: String {
        if seconds <= 12 * 3600 { return "\(max(1, Int((seconds / 3600).rounded())))h" }
        if (6 * 86400...8 * 86400).contains(seconds) { return "wk" }
        return "\(Int((seconds / 86400).rounded()))d"
    }

    private var periodLabel: String {
        if seconds <= 12 * 3600 {
            let h = max(1, Int((seconds / 3600).rounded()))
            return T("\(h)시간", "\(h)-hour")
        }
        if (6 * 86400...8 * 86400).contains(seconds) { return T("주간", "Weekly") }
        let d = Int((seconds / 86400).rounded())
        return T("\(d)일", "\(d)-day")
    }
}

/// 노치 양옆 AI 칸 하나에 보일 것
enum AISide: Equatable {
    case mark
    case window(UsageWindow)
}

struct ServiceUsage: Codable, Equatable {
    /// 서비스가 주는 한도들 (짧은 기간부터). 5시간·주간이 둘 다 없고 30일 한도 하나만 있는 경우도 있다.
    var windows: [UsageWindow] = []
    var fetched: Date
    /// "login"(다시 로그인 필요) · "parse"(페이지를 읽지 못함) · 그 밖의 오류
    var error: String?

    var hasData: Bool { !windows.isEmpty }

    init(windows: [UsageWindow] = [], fetched: Date, error: String? = nil) {
        // 같은 한도는 하나만. 전체 한도를 짧은 기간부터, 그 뒤에 모델·기능별 한도
        var seen = Set<String>()
        self.windows = windows.sorted { ($0.name != nil ? 1 : 0, $0.seconds, $0.name ?? "") < ($1.name != nil ? 1 : 0, $1.seconds, $1.name ?? "") }
            .filter { seen.insert($0.id).inserted }
        self.fetched = fetched
        self.error = error
    }

    /// 노치 양옆 칸. `left`·`right`는 설정에서 고른 것("mark" 또는 한도 id, nil이면 자동).
    /// 자동: 전체 한도가 둘 이상이면 가장 짧은 것과 가장 긴 것, 하나면 서비스 기호와 그 한도.
    /// 고른 한도가 지금 없으면(요금제가 바뀜 등) 그 칸은 자동으로 돌아가고, 양쪽이 같아지지 않게 한다.
    func sides(left: String?, right: String?) -> (left: AISide, right: AISide)? {
        guard !windows.isEmpty else { return nil }
        let overall = windows.filter { $0.name == nil }
        let pool = overall.isEmpty ? windows : overall
        let auto: (AISide, AISide) = pool.count > 1 ? (.window(pool[0]), .window(pool[pool.count - 1])) : (.mark, .window(pool[0]))
        func pick(_ choice: String?) -> AISide? {
            guard let choice else { return nil }
            if choice == "mark" { return .mark }
            return windows.first { $0.id == choice }.map(AISide.window)
        }
        let l = pick(left), r = pick(right)
        var result = (left: l ?? auto.0, right: r ?? auto.1)
        if result.left == result.right {
            // 한쪽만 고른 경우: 자동인 쪽을 고른 것과 겹치지 않는 다른 후보로
            let candidates = [auto.0, auto.1, .mark] + windows.map(AISide.window)
            if l == nil { result.left = candidates.first { $0 != result.right } ?? .mark }
            else { result.right = candidates.first { $0 != result.left } ?? .mark }
        }
        return result
    }

    /// 칸에 고를 수 있는 것: 서비스 기호와 지금 있는 한도들
    var sideChoices: [(id: String, label: String)] {
        [("mark", T("서비스 기호", "Service mark"))] + windows.map { ($0.id, $0.label) }
    }

    /// 설정 창(도우미 프로세스)이 고를 수 있는 한도를 보이도록 본 앱이 저장한 마지막 사용량을 읽는다
    static func cached() -> [AIService: ServiceUsage] {
        guard let data = UserDefaults.standard.data(forKey: UsageStore.cacheKey),
              let saved = try? JSONDecoder().decode([String: ServiceUsage].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in AIService(rawValue: k).map { ($0, v) } })
    }
}

/// AI 사용량 저장소 (본 앱).
/// 실제 조회는 같은 실행 파일을 `--usage-fetch=`로 띄운 짧은 도우미가 웹(WebKit)에서 하고 결과만 받는다.
/// 도우미가 끝나면 WebKit 메모리는 통째로 운영체제에 돌아간다.
///
/// 새로고침 시점:
/// - 상시 표시를 켰으면 설정한 간격마다 (두 손가락으로 잠시 가려도 계속)
/// - 꺼 두었으면 백그라운드에서는 하지 않고, 노치를 길게 눌러 사용량 페이지를 열 때만
final class UsageStore: ObservableObject {
    @Published private(set) var usage: [AIService: ServiceUsage] = [:]
    @Published private(set) var refreshing = false

    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    static let cacheKey = "aiUsageCache"

    init(center: ActivityCenter) {
        self.center = center
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let saved = try? JSONDecoder().decode([String: ServiceUsage].self, from: data) {
            for (k, v) in saved { if let s = AIService(rawValue: k) { usage[s] = v } }
        }
    }

    /// 연결된 서비스. 설정 → 기본에서 AI 사용량을 끄면 없는 것으로 본다 (새로고침·상시 표시 모두 멈춤)
    var connected: [AIService] {
        settings.isHomeFeatureOn("usage") ? AIService.connected(settings.aiConnected) : []
    }

    func start() {
        settings.$aiUsagePinned.map { _ in () }
            .merge(with: settings.$aiRefreshMinutes.map { _ in () },
                   settings.$monitorContent.map { _ in () },
                   settings.$displayContent.map { _ in () },
                   settings.$aiConnected.map { _ in () },
                   settings.$aiUsageService.map { _ in () },
                   settings.$aiUsageStyle.map { _ in () },
                   settings.$homeDisabled.map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.settingsChanged() }
            .store(in: &cancellables)
        // 우선순위가 더 높은 상시 항목에 가려졌는지 (바뀐 뒤 잠깐 있다가 확인)
        center.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in self?.updateCoverage() }
            .store(in: &cancellables)
    }

    /// 상시 표시가 다른 상시 항목(우선순위가 더 높은 것)에 가려져 있으면 백그라운드 새로고침을 쉰다.
    /// 두 손가락으로 잠시 숨긴 것은 가린 것으로 보지 않는다. 다시 보이면 이어서 하고, 오래됐으면 바로 한 번.
    /// (가려진 동안에도 길게 눌러 사용량 페이지를 넘겨 보면 그때 새로고침한다 — pageAppeared)
    private var covered = false

    /// AI 사용량이 노치에 상시 표시되는지 (AI만 또는 AI 및 자원)
    private var aiLive: Bool { !settings.monitorKindsNeeded.isDisjoint(with: [.aiUsage, .monitor]) }

    /// 두 손가락으로 숨긴 시각. 숨긴 지 새로고침 주기 한 번이 지나면 다시 보일 때까지 쉰다.
    private var hiddenSince: Date?
    private var restingWhileHidden: Bool {
        hiddenSince.map { Date().timeIntervalSince($0) >= max(1, settings.aiRefreshMinutes) * 60 } ?? false
    }

    private func updateHidden() {
        if center.persistentHidden {
            if hiddenSince == nil { hiddenSince = Date() }
        } else if hiddenSince != nil {
            let rested = restingWhileHidden
            hiddenSince = nil
            // 쉬는 동안 놓친 만큼, 다시 보이면 바로 한 번
            if rested, aiLive, !covered, isStale(max(1, settings.aiRefreshMinutes) * 60) { refresh() }
        }
    }

    private func updateCoverage() {
        updateHidden()
        let shown: ActivityKind = settings.monitorKindsNeeded.contains(.monitor) ? .monitor : .aiUsage
        let now = aiLive && center.persistentKinds.contains(shown)
            && center.orderedPersistent.first?.kind != shown
        guard now != covered else { return }
        covered = now
        reschedule()
        if !covered, aiLive, isStale(max(1, settings.aiRefreshMinutes) * 60) { refresh() }
    }

    private var lastConnected: [AIService] = []

    private func settingsChanged() {
        // 로그아웃한 서비스의 기록은 지운다
        let now = connected
        for s in AIService.allCases where !now.contains(s) && usage[s] != nil { usage[s] = nil }
        let newlyConnected = now.filter { !lastConnected.contains($0) }
        lastConnected = now
        reschedule()
        // 새로 연결했거나 상시 표시를 켰는데 기록이 오래됐으면 바로 한 번
        if !newlyConnected.isEmpty || (aiLive && isStale(60)) { refresh() }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard aiLive, !connected.isEmpty, !covered else { return }
        let interval = max(1, settings.aiRefreshMinutes) * 60
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, !self.restingWhileHidden else { return }
            self.refresh()
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func isStale(_ seconds: TimeInterval) -> Bool {
        connected.contains { s in usage[s].map { Date().timeIntervalSince($0.fetched) > seconds } ?? true }
    }

    /// 사용량 페이지가 열렸을 때: 1분 넘게 지났으면 새로고침
    func pageAppeared() {
        if isStale(60) { refresh() }
    }

    func refresh() {
        let services = connected
        guard !refreshing, !services.isEmpty, let exe = Bundle.main.executableURL else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.runFetcher(exe: exe, services: services)
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                for (s, u) in result {
                    // 일시적 오류면 이전 값을 남겨 두고 오류만 표시
                    if !u.hasData, var old = self.usage[s], old.hasData {
                        old.error = u.error
                        self.usage[s] = old
                    } else {
                        self.usage[s] = u
                    }
                }
                self.save()
            }
        }
    }

    private static func runFetcher(exe: URL, services: [AIService]) -> [AIService: ServiceUsage] {
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--usage-fetch=" + services.map(\.rawValue).joined(separator: ",")]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        guard let decoded = try? JSONDecoder().decode([String: ServiceUsage].self, from: data) else { return [:] }
        var result: [AIService: ServiceUsage] = [:]
        for (k, v) in decoded { if let s = AIService(rawValue: k) { result[s] = v } }
        return result
    }

    private func save() {
        let dict = Dictionary(uniqueKeysWithValues: usage.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(dict) { UserDefaults.standard.set(data, forKey: Self.cacheKey) }
    }

    // MARK: - 상시 표시할 서비스 (게시는 MonitorCoordinator)

    /// 상시 표시할 서비스: 설정에서 고른 것, 연결이 안 돼 있으면 연결된 첫 서비스
    var pinnedService: AIService? {
        let list = connected
        if let s = AIService(rawValue: settings.aiUsageService), list.contains(s) { return s }
        return list.first
    }
}

/// 노치 안 사용량 표시: 위에 작은 이름(5h·주간), 아래에 퍼센트 또는 원형
struct UsageGlyph: View {
    var label: String
    var percent: Double?
    var ring: Bool
    var tint: Color
    var large = false

    /// 초기화까지 남은 시간 (노치용 짧은 글자: 29d · 4h · 12m)
    static func shortRemaining(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        if s >= 86400 { return "\(s / 86400)d" }
        if s >= 3600 { return "\(s / 3600)h" }
        return "\(max(1, s / 60))m"
    }

    static func color(_ percent: Double?, tint: Color) -> Color {
        guard let p = percent else { return .white.opacity(0.4) }
        return p >= 90 ? .red : (p >= 70 ? .orange : tint)
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: large ? 10 : 8, weight: large ? .semibold : .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize()
            if ring {
                RingGauge(value: (percent ?? 0) / 100, tint: Self.color(percent, tint: tint), lineWidth: large ? 3 : 2.2)
                    .frame(width: large ? 22 : 13, height: large ? 22 : 13)
            } else {
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                    .font(.system(size: large ? 16 : 12.5, weight: large ? .semibold : .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle((percent ?? 0) >= 90 ? .red : .white)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// 홈·팝업의 AI 사용량 페이지: 서비스마다 한 줄 (5시간 · 주간)
struct UsagePage: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var settings = AppSettings.shared
    var openSettings: () -> Void

    var body: some View {
        let services = store.connected
        VStack(spacing: 6) {
            HStack {
                Text(T("AI 사용량", "AI Usage"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if store.refreshing {
                    ProgressView().controlSize(.mini).tint(.white)
                } else if let latest = services.compactMap({ store.usage[$0]?.fetched }).max() {
                    Text(Self.ago(latest)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.refreshing || services.isEmpty)
            }
            if services.isEmpty {
                Spacer(minLength: 0)
                Button(action: openSettings) {
                    VStack(spacing: 4) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 18))
                        Text(T("설정 → 상호작용 → 실시간 모니터링에서 로그인하세요", "Sign in under Settings → Interactions → Live Monitoring"))
                            .font(.system(size: 10.5))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            } else {
                ForEach(services) { service in
                    row(service, store.usage[service])
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 2)
        .onAppear { store.pageAppeared() }
    }

    private func row(_ service: AIService, _ u: ServiceUsage?) -> some View {
        HStack(spacing: 8) {
            Button { NSWorkspace.shared.open(service.usagePageURL) } label: {
                HStack(spacing: 5) {
                    Circle().fill(service.tint).frame(width: 7, height: 7)
                    Text(service.shortName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let u, u.hasData, u.error != nil {
                        // 이전 값을 보여 주는 중: 이번 새로고침은 실패 (예: 다시 로그인 필요)
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help(Self.errorText(u.error, loading: false))
                    }
                }
                .frame(width: 66, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(T("사용량 페이지 열기", "Open usage page"))
            if let u, u.hasData {
                // 한도가 몇 개든 그대로 (하나뿐이면 한 칸이 줄 전체를 쓴다)
                ForEach(u.windows.prefix(3), id: \.id) { w in
                    meter(w.label, w, tint: service.tint)
                }
            } else {
                Text(Self.errorText(u?.error, loading: u == nil))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 30)
    }

    private func meter(_ label: String, _ w: UsageWindow?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                Text(w.map { "\(Int($0.percent.rounded()))%" } ?? "–")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
            }
            BarGauge(value: (w?.percent ?? 0) / 100, tint: UsageGlyph.color(w?.percent, tint: tint))
            Text(w?.resetsAt.map(Self.resetText) ?? " ")
                .font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    static func errorText(_ error: String?, loading: Bool) -> String {
        if loading { return T("불러오는 중…", "Loading…") }
        switch error {
        case "login": return T("다시 로그인이 필요합니다", "Sign in again")
        case "parse": return T("사용량 페이지를 읽지 못했습니다", "Couldn't read the usage page")
        case "nodata": return T("이 계정에는 사용량 한도 정보가 없습니다", "No usage limits for this account")
        default: return T("불러오지 못했습니다", "Couldn't load")
        }
    }

    static func resetText(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return T("\(d)일 \(h)시간 후 초기화", "Resets in \(d)d \(h)h") }
        if h > 0 { return T("\(h)시간 \(m)분 후 초기화", "Resets in \(h)h \(m)m") }
        return T("\(m)분 후 초기화", "Resets in \(m)m")
    }

    static func ago(_ date: Date) -> String {
        let m = Int(Date().timeIntervalSince(date) / 60)
        if m < 1 { return T("방금", "just now") }
        if m < 60 { return T("\(m)분 전", "\(m)m ago") }
        return T("\(m / 60)시간 전", "\(m / 60)h ago")
    }
}
