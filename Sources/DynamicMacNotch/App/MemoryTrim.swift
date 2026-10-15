import Foundation
import Darwin

/// 큰 일회성 작업(전체화면 창, 스크린샷, 팝업 전환) 뒤에 해제된 메모리는 할당기가 쥐고 있어
/// 실제 사용량(물리 footprint)에 계속 잡힌다. 작업이 끝나고 잠잠해지면 빈 페이지를 운영체제에 돌려준다.
/// (macOS 14~15의 기존 할당기에서 효과가 있고, xzone 할당기를 쓰는 최신 macOS에서는 0을 돌려줘 아무 일도 하지 않는다)
enum MemoryTrim {
    private static var pending: DispatchWorkItem?

    /// 마지막 호출 3초 뒤 한 번만 실행 (연달아 불려도 한 번)
    static func soon() {
        pending?.cancel()
        let work = DispatchWorkItem {
            malloc_zone_pressure_relief(nil, 0)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
