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

/// 한 기간(5시간·주간)의 사용량
struct UsageWindow: Codable, Equatable {
    /// 사용한 비율 0~100
    var percent: Double
    var resetsAt: Date?
}

struct ServiceUsage: Codable, Equatable {
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    var fetched: Date
    /// "login"(다시 로그인 필요) · "parse"(페이지를 읽지 못함) · 그 밖의 오류
    var error: String?

    var hasData: Bool { fiveHour != nil || weekly != nil }
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
    private static let cacheKey = "aiUsageCache"

    init(center: ActivityCenter) {
        self.center = center
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let saved = try? JSONDecoder().decode([String: ServiceUsage].self, from: data) {
            for (k, v) in saved { if let s = AIService(rawValue: k) { usage[s] = v } }
        }
    }

    var connected: [AIService] { AIService.connected(settings.aiConnected) }

    func start() {
        settings.$aiUsagePinned.map { _ in () }
            .merge(with: settings.$aiRefreshMinutes.map { _ in () },
                   settings.$aiConnected.map { _ in () },
                   settings.$aiUsageService.map { _ in () },
                   settings.$aiUsageStyle.map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.settingsChanged() }
            .store(in: &cancellables)
    }

    private var lastConnected: [AIService] = []

    private func settingsChanged() {
        // 로그아웃한 서비스의 기록은 지운다
        let now = connected
        for s in AIService.allCases where !now.contains(s) && usage[s] != nil { usage[s] = nil }
        let newlyConnected = now.filter { !lastConnected.contains($0) }
        lastConnected = now
        reschedule()
        updatePersistent()
        // 새로 연결했거나 상시 표시를 켰는데 기록이 오래됐으면 바로 한 번
        if !newlyConnected.isEmpty || (settings.aiUsagePinned && isStale(60)) { refresh() }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard settings.aiUsagePinned, !connected.isEmpty else { return }
        let interval = max(5, settings.aiRefreshMinutes) * 60
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
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
                self.updatePersistent()
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

    // MARK: - 노치 상시 표시 (왼쪽 5시간 · 오른쪽 주간)

    /// 상시 표시할 서비스: 설정에서 고른 것, 연결이 안 돼 있으면 연결된 첫 서비스
    var pinnedService: AIService? {
        let list = connected
        if let s = AIService(rawValue: settings.aiUsageService), list.contains(s) { return s }
        return list.first
    }

    private func updatePersistent() {
        guard settings.aiUsagePinned, let service = pinnedService else {
            center.removePersistent(.aiUsage)
            return
        }
        center.setPersistent(Self.activity(service: service, usage: usage[service], ring: settings.aiUsageStyle == .ring))
    }

    static func activity(service: AIService, usage: ServiceUsage?, ring: Bool) -> NotchActivity {
        let five = usage?.fiveHour?.percent, week = usage?.weekly?.percent
        func text(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "–" }
        return NotchActivity(
            kind: .aiUsage, priority: ActivityPriority.pinned, symbol: "gauge.medium", tint: service.tint,
            value: .usage(label: "wk", percent: week, ring: ring),
            title: T("\(service.name) 사용량", "\(service.name) Usage"),
            subtitle: T("5시간 \(text(five)) · 주간 \(text(week))", "5h \(text(five)) · Weekly \(text(week))"),
            wing: NotchActivity.compactWing,
            leadingValue: .usage(label: "5h", percent: five, ring: ring))
    }
}

/// 노치 안 사용량 표시: 위에 작은 이름(5h·주간), 아래에 퍼센트 또는 원형
struct UsageGlyph: View {
    var label: String
    var percent: Double?
    var ring: Bool
    var tint: Color
    var large = false

    static func color(_ percent: Double?, tint: Color) -> Color {
        guard let p = percent else { return .white.opacity(0.4) }
        return p >= 90 ? .red : (p >= 70 ? .orange : tint)
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: large ? 10 : 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize()
            if ring {
                RingGauge(value: (percent ?? 0) / 100, tint: Self.color(percent, tint: tint), lineWidth: large ? 3 : 2.2)
                    .frame(width: large ? 22 : 13, height: large ? 22 : 13)
            } else {
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                    .font(.system(size: large ? 16 : 12.5, weight: .semibold, design: .rounded))
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
                        Text(T("설정 → 상호작용 → AI 사용량에서 로그인하세요", "Sign in under Settings → Interactions → AI Usage"))
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
                meter("5h", u.fiveHour, tint: service.tint)
                meter(T("주간", "Weekly"), u.weekly, tint: service.tint)
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
