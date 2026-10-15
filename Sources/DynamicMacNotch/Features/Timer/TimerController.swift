import SwiftUI

/// 홈의 타이머 (가이드라인 5.1). 실행 중에는 지속 액티비티로 노치에 남는다.
/// 남은 시간은 Date 기준으로 계산해 잠자기 후에도 정확하다.
final class TimerController: ObservableObject {

    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var total: TimeInterval = 0
    @Published private(set) var now = Date()

    private let center: ActivityCenter
    private weak var viewModel: NotchViewModel?
    private var ticker: Timer?

    init(center: ActivityCenter, viewModel: NotchViewModel) {
        self.center = center
        self.viewModel = viewModel
    }

    var isActive: Bool { endDate != nil || pausedRemaining != nil }
    var isPaused: Bool { pausedRemaining != nil }

    var remaining: TimeInterval {
        if let p = pausedRemaining { return p }
        guard let end = endDate else { return 0 }
        return max(0, end.timeIntervalSince(now))
    }

    var progress: Double { total > 0 ? remaining / total : 0 }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - 시·분·초 설정 (두 손가락 상하 스크롤)

    enum Unit: Int, CaseIterable {
        case hour, minute, second
        var range: Int { self == .hour ? 24 : 60 }
        var label: String {
            switch self {
            case .hour: return T("시", "H")
            case .minute: return T("분", "M")
            case .second: return T("초", "S")
            }
        }
    }

    /// 설정 중인 시간 [시, 분, 초]
    @Published var draft: [Int] = {
        let saved = UserDefaults.standard.array(forKey: "timerDraft") as? [Int]
        return saved?.count == 3 ? saved! : [0, 5, 0]
    }()
    /// 커서가 올라가 있는 칸 (스크롤로 조절할 대상)
    @Published var hoveredUnit: Unit?
    /// 클릭으로 고른 칸 (호버가 안 잡히는 경우 대비)
    @Published var selectedUnit: Unit = .minute
    /// 설정 화면(시·분·초)이 노치에 보이는 중인지
    var draftVisible = false
    private var scrollRemainder: CGFloat = 0

    /// 키보드로 숫자를 입력 중인 칸
    @Published var editingUnit: Unit?

    func beginEditing(_ unit: Unit) {
        selectedUnit = unit
        editingUnit = unit
    }

    /// 입력한 숫자를 반영한다. 범위를 넘으면 최댓값으로 맞춘다 (시 23, 분·초 59).
    func commitEdit(_ unit: Unit, text: String, emptyAsZero: Bool = false) {
        if let n = Int(text) ?? (emptyAsZero && text.isEmpty ? 0 : nil) {
            var values = draft
            let newValue = min(max(0, n), unit.range - 1)
            lastStepUp = newValue >= values[unit.rawValue]
            values[unit.rawValue] = newValue
            draft = values
            UserDefaults.standard.set(draft, forKey: "timerDraft")
        }
    }

    func endEditing() { editingUnit = nil }

    /// 입력 중인 칸이 등록하는 '지금 값으로 확정' 처리 (빈칸 → 00 여부)
    var commitActiveField: ((_ emptyAsZero: Bool) -> Void)?

    /// 바깥(검은 배경)을 누르거나 시작을 누르면 입력 중인 숫자를 확정한다. 빈칸이면 00.
    func finishEditing() {
        guard editingUnit != nil else { return }
        if let commit = commitActiveField { commit(true) } else { endEditing() }
    }

    /// 마지막 변경 방향 (숫자 굴러가는 애니메이션 방향)
    @Published var lastStepUp = true

    var draftSeconds: Int { draft[0] * 3600 + draft[1] * 60 + draft[2] }

    /// 컨트롤러가 넘겨주는 세로 스크롤 (손가락 위 = 양수). 처리하면 true.
    func handleScroll(fingerDY: CGFloat) -> Bool {
        guard !isActive, draftVisible else { return false }
        // 키보드로 입력하는 동안에는 스크롤로 숫자를 바꾸지 않는다 (스크롤은 삼켜서 다른 동작도 막음)
        guard editingUnit == nil else { return true }
        let unit = hoveredUnit ?? selectedUnit
        scrollRemainder += fingerDY
        let step: CGFloat = 12
        while abs(scrollRemainder) >= step {
            let dir = scrollRemainder > 0 ? 1 : -1
            scrollRemainder -= CGFloat(dir) * step
            var values = draft
            lastStepUp = dir > 0
            values[unit.rawValue] = (values[unit.rawValue] + dir + unit.range) % unit.range
            draft = values
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        return true
    }

    func endScroll() {
        scrollRemainder = 0
        UserDefaults.standard.set(draft, forKey: "timerDraft")
    }

    func startDraft() {
        guard draftSeconds > 0 else { return }
        start(seconds: draftSeconds)
    }


    func start(seconds: Int) {
        total = TimeInterval(seconds)
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(total)
        startTicker()
        tick()
    }


    func pause() {
        guard let end = endDate else { return }
        pausedRemaining = max(0, end.timeIntervalSinceNow)
        endDate = nil
        ticker?.invalidate()
        publish()
    }

    func resume() {
        guard let p = pausedRemaining else { return }
        endDate = Date().addingTimeInterval(p)
        pausedRemaining = nil
        startTicker()
        tick()
    }

    func cancel() {
        ticker?.invalidate()
        endDate = nil
        pausedRemaining = nil
        center.removePersistent(.timer)
    }

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        now = Date()
        if endDate != nil, remaining <= 0 {
            finish()
            return
        }
        publish()
    }

    private func publish() {
        guard isActive else { return }
        center.setPersistent(NotchActivity(
            kind: .timer,
            priority: ActivityPriority.timer,
            symbol: isPaused ? "pause.fill" : "timer",
            tint: .orange,
            value: .text(Self.format(remaining)),
            title: T("타이머", "Timer"),
            wing: 64
        ))
    }

    private func finish() {
        let totalText = Self.format(total)
        cancel()
        center.post(NotchActivity(
            kind: .timer,
            priority: ActivityPriority.batteryLow,
            presentation: .detail,
            duration: 6,
            symbol: "timer",
            tint: .orange,
            value: .text(T("완료", "Done")),
            title: T("타이머 종료", "Timer Done"),
            subtitle: T("\(totalText) 타이머가 끝났습니다", "Your \(totalText) timer is done")
        ))
        NSSound(named: "Glass")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.viewModel?.shake() }
    }
}

struct CircleButton: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 30
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(tint.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
