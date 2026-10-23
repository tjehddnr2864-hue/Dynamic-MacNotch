import Foundation
import Darwin

/// 메모리 지킴이.
/// 최신 macOS의 할당기(xzone)는 앱이 해제한 메모리를 운영체제에 돌려주지 않아, 큰 작업 뒤에는 쓰지 않는 메모리가
/// 사용량에 그대로 남는다. 앱 안에서 기능을 '리셋'해도 이 메모리는 줄지 않으므로, 확실하게 돌려주는 방법은 프로세스를 새로 시작하는 것뿐이다.
///
/// 그래서: 5분마다(그리고 스크린샷·미리보기처럼 큰 작업 직후) 사용량을 재고,
/// 기준(70MB)을 넘으면 ① 캐시를 비운 뒤 다시 재고 ② 그래도 넘으면 앱이 쉬고 있을 때
/// (확장·알림·녹화·통화·타이머·전송·설정 창 등이 없을 때) 조용히 다시 시작한다.
/// 음악은 다른 앱에서 계속 재생되므로 끊기지 않고, 노치는 1초 안에 같은 상태로 돌아온다.
final class MemoryGuard {
    static let shared = MemoryGuard()

    static let defaultLimitMB: Double = 70
    #if DEV
    static var limitMB: Double = defaultLimitMB   // 개발용: 시험 때 낮춰 본다
    #else
    static let limitMB: Double = defaultLimitMB
    #endif

    /// 지금 다시 시작해도 되는지 (AppDelegate가 연결)
    var isIdle: (() -> Bool)?
    /// 캐시 비우기 (AppDelegate가 연결)
    var releaseCaches: (() -> Void)?
    /// 조용히 다시 시작 (AppDelegate가 연결)
    var relaunch: (() -> Void)?

    private let settings = AppSettings.shared
    private var timer: Timer?
    private var pendingCheck: DispatchWorkItem?
    private var idleWait: Timer?

    func start() {
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 큰 작업이 끝난 뒤 10초 뒤에 한 번 점검 (연달아 불려도 한 번)
    func checkSoon() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    /// 지금 사용 중인 물리 메모리 (활성 상태 보기의 '메모리'와 같은 값)
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    #if DEV
    func debugCheckNow() { check() }
    #endif

    private func check() {
        guard settings.memoryGuard, idleWait == nil, Self.footprintMB() > Self.limitMB else { return }
        releaseCaches?()
        MemoryTrim.soon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, Self.footprintMB() > Self.limitMB else { return }
            self.waitForIdleThenRelaunch()
        }
    }

    /// 쉬는 순간을 20초마다 확인하다가 다시 시작한다. 30분 안에 쉬지 않으면 다음 점검으로 미룬다.
    private func waitForIdleThenRelaunch() {
        guard idleWait == nil else { return }
        let deadline = Date().addingTimeInterval(30 * 60)
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] timer in
            guard let self else { return }
            if Date() > deadline || !self.settings.memoryGuard {
                timer.invalidate()
                self.idleWait = nil
                return
            }
            guard self.isIdle?() == true else { return }
            timer.invalidate()
            self.idleWait = nil
            self.relaunch?()
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        idleWait = t
    }
}
