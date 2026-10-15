import SwiftUI

/// 액티비티 우선순위 큐. 일회성(transient) 액티비티 하나와 지속(persistent) 액티비티 여러 개를 관리하고,
/// 노치에 올릴 '주 액티비티'를 결정한다.
final class ActivityCenter: ObservableObject {
    @Published private(set) var transient: NotchActivity?
    @Published private(set) var persistent: [ActivityKind: NotchActivity] = [:]
    /// 현재 일회성 액티비티를 상세 카드로 보여 주는 중인지.
    @Published private(set) var showingDetail = false

    private var pending: [NotchActivity] = []
    private var expireWork: DispatchWorkItem?
    private var detailWork: DispatchWorkItem?
    private var expireDate: Date?

    /// 마우스가 노치 위에 있는 동안 표시 타이머를 멈춘다.
    var paused = false {
        didSet {
            guard paused != oldValue, transient != nil else { return }
            if paused {
                expireWork?.cancel()
            } else {
                let remaining = max(1.5, expireDate.map { $0.timeIntervalSinceNow } ?? 1.5)
                scheduleExpire(after: remaining)
            }
        }
    }

    /// 노치에 표시할 주 액티비티.
    var displayed: NotchActivity? {
        // 잠금 상태에서는 자물쇠만 보인다 (다른 정보는 잠금화면에 노출하지 않는다).
        lockActivity ?? transient ?? topPersistent
    }

    /// 잠금/잠금 해제 표시 (가이드라인 5.12). 설정되면 다른 모든 표시보다 앞선다.
    @Published var lockActivity: NotchActivity?

    /// 두 손가락 위로 제스처로 상시 표시 항목을 숨긴 상태 (아래로 제스처 시 다시 표시).
    @Published private(set) var persistentHidden = false

    /// 설정의 우선순위 순서로 고른 상시 표시 항목 (숨김 상태면 nil).
    var topPersistent: NotchActivity? {
        guard !persistentHidden else { return nil }
        return orderedPersistent.first
    }

    var orderedPersistent: [NotchActivity] {
        let order = AppSettings.shared.persistentOrder
        func rank(_ a: NotchActivity) -> Int { order.firstIndex(of: a.kind.rawValue) ?? order.count }
        return persistent.values.sorted { rank($0) < rank($1) }
    }

    var hasPersistent: Bool { !persistent.isEmpty }

    func setPersistentHidden(_ hidden: Bool) {
        guard hidden != persistentHidden, hasPersistent || !hidden else { return }
        persistentHidden = hidden
    }

    /// 주 액티비티 외에 진행 중인 지속 액티비티 (보조 원형 표시용).
    var secondary: NotchActivity? {
        guard let main = displayed else { return nil }
        return orderedPersistent.first { $0.kind != main.kind }
    }

    // MARK: - 일회성

    func post(_ activity: NotchActivity) {
        if let current = transient {
            if current.kind == activity.kind {
                // 같은 종류: 새 카드를 띄우지 않고 값만 갱신하고 타이머를 리셋한다.
                var updated = activity
                updated.id = current.id
                show(updated, restartDetail: false)
                return
            }
            if activity.priority < current.priority {
                pending.append(activity)
                pending.sort { $0.priority > $1.priority }
                // 대기열이 쌓이지 않게 최대 4개만 (우선순위 낮은 것부터 버림)
                if pending.count > 4 { pending.removeLast(pending.count - 4) }
                return
            }
        }
        show(activity, restartDetail: true)
    }

    /// 표시 중인 같은 종류 액티비티의 값만 바꾼다(타이머는 유지).
    func update(_ kind: ActivityKind, _ mutate: (inout NotchActivity) -> Void) {
        if var t = transient, t.kind == kind {
            mutate(&t)
            if t != transient { transient = t }
        }
        if var p = persistent[kind] {
            mutate(&p)
            if p != persistent[kind] { persistent[kind] = p }
        }
    }

    func dismissTransient() {
        MemoryTrim.soon()
        expireWork?.cancel()
        detailWork?.cancel()
        transient = nil
        showingDetail = false
        if !pending.isEmpty {
            show(pending.removeFirst(), restartDetail: true)
        }
    }

    // MARK: - 지속

    func setPersistent(_ activity: NotchActivity) {
        // 새 상시 항목이 시작되면 숨김을 풀어 보여 준다.
        if persistent[activity.kind] == nil { persistentHidden = false }
        var a = activity
        if let existing = persistent[activity.kind] {
            a.id = existing.id
            // 내용이 같으면 다시 게시하지 않는다 (노치 전체를 다시 그리는 일을 막음)
            if existing == a { return }
        }
        persistent[activity.kind] = a
    }

    func removePersistent(_ kind: ActivityKind) {
        guard persistent[kind] != nil else { return }
        persistent[kind] = nil
        if persistent.isEmpty { persistentHidden = false }
    }

    // MARK: - 내부

    private func show(_ activity: NotchActivity, restartDetail: Bool) {
        transient = activity
        let duration = activity.duration ?? AppSettings.shared.transientDuration

        switch activity.presentation {
        case .compact:
            showingDetail = false
        case .detail:
            showingDetail = true
        case .detailThenCompact(let detailTime):
            if restartDetail {
                showingDetail = true
                detailWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.showingDetail = false }
                detailWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + detailTime, execute: work)
            }
        }
        if !paused {
            scheduleExpire(after: duration)
        } else {
            expireDate = Date().addingTimeInterval(duration)
        }
    }

    private func scheduleExpire(after seconds: TimeInterval) {
        expireWork?.cancel()
        expireDate = Date().addingTimeInterval(seconds)
        let work = DispatchWorkItem { [weak self] in self?.dismissTransient() }
        expireWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
