import SwiftUI

enum ActivityKind: String, Hashable {
    case lock, battery, timer, calendar, media, download, airdrop, screenshot, recording, network, hotspot, bluetooth, focus, focusPinned, hud, demo, call, aiUsage
}

/// 우선순위: 값이 클수록 먼저 표시된다 (가이드라인 2.3).
enum ActivityPriority {
    static let hud = 100
    static let call = 95
    static let lock = 90
    static let batteryLow = 85
    static let screenshot = 70
    static let info = 50
    static let recording = 40
    static let timer = 35
    static let download = 30
    static let media = 20
    static let pinned = 10
}

/// 노치 오른쪽(또는 상세 카드)에 표시할 값.
enum ActivityValue: Equatable {
    case none
    case text(String)
    case percent(Double)      // 0...1, 숫자로 표시
    case ring(Double)         // 0...1, 원형 게이지
    case bar(Double)          // 0...1, 가로 바
    case ringPercent(Double)  // 0...1, 원형 + 숫자
    case recordingDot
    case waveform(Bool)       // 재생 중이면 움직이는 파형
    case spinner              // 진행률을 알 수 없을 때 회전 링
    case check                // 완료 체크
    case bigNumber(Double)    // 0...1, % 없이 큰 숫자 (밝기·음량 HUD)
    case elapsed(Date)        // 그 시각부터 흐른 시간 (화면 녹화: 오른쪽 녹화 시간)
    case usage(label: String, percent: Double?, ring: Bool)   // AI 사용량: 위 작은 이름(5h·wk), 아래 퍼센트 또는 원형
    case labeledText(label: String, text: String)            // 위 작은 이름, 아래 글자 (AI 사용량 초기화까지 남은 시간)
}

enum ActivityPresentation: Equatable {
    /// 노치 높이 그대로 좌우로만 넓어진다.
    case compact
    /// 좌우 및 아래로 커진 카드로 표시된다.
    case detail
    /// 상세로 먼저 떴다가 지정 시간 뒤 컴팩트로 줄어든다 (다운로드 등).
    case detailThenCompact(TimeInterval)
}

struct NotchActivity: Identifiable, Equatable {
    /// 모든 컴팩트(좌우로만 넓어지는) 표시의 날개 폭 · 블루투스 연결 기준으로 통일
    static let compactWing: CGFloat = 56
    /// 컴팩트 글자 · 블루투스 배터리 수치와 같은 글꼴
    static let compactFont = Font.system(size: 13.5, weight: .medium, design: .rounded)
    /// 컴팩트 숫자(배터리·음량·타이머 등)는 조금 크게
    static let compactNumberFont = Font.system(size: 15.5, weight: .medium, design: .rounded)
    /// HUD(음량·밝기)·배터리 숫자는 그보다 아주 조금 작게
    static let compactSmallNumberFont = Font.system(size: 14.5, weight: .medium, design: .rounded)

    static func compactNumberFont(for kind: ActivityKind) -> Font {
        kind == .hud || kind == .battery ? compactSmallNumberFont : compactNumberFont
    }

    /// 잠금 자물쇠만 좁게, 나머지는 모두 같은 폭
    static func wing(for activity: NotchActivity?) -> CGFloat {
        activity?.kind == .lock ? activity!.wing : compactWing
    }

    var id = UUID()
    var kind: ActivityKind
    var priority: Int = ActivityPriority.info
    var presentation: ActivityPresentation = .compact
    /// nil이면 설정의 '일회성 알림 표시 시간'을 따른다. 지속 액티비티에서는 무시된다.
    var duration: TimeInterval? = nil
    var symbol: String
    var tint: Color = .white
    var value: ActivityValue = .none
    var title: String? = nil
    var subtitle: String? = nil
    /// 상세 카드 오른쪽 값. nil이면 value를 쓴다.
    var detailValue: ActivityValue? = nil
    /// 컴팩트 상태에서 노치 양옆으로 늘어나는 폭(pt).
    var wing: CGFloat = 60
    /// 좌측 아이콘 대신 표시할 이미지 (앨범아트, 스크린샷 썸네일 등)
    var artwork: NSImage? = nil
    /// 상세 카드 높이(노치 아래 추가 높이). nil이면 기본값.
    var detailHeight: CGFloat? = nil
    /// 컴팩트에서 좌우를 바꿔 그린다 (블루투스: 좌 배터리, 우 기기 아이콘)
    var swapSides: Bool = false
    /// 숫자·글자 값의 색 (nil이면 흰색). 블루투스 배터리: 초록 / 15% 미만 빨강
    var valueTint: Color? = nil
    /// 배터리 알림: 같은 모양의 배터리 아이콘(잔량 채움, 충전 중이면 번개)을 그린다.
    var battery: BatteryGlyphInfo? = nil
    /// 관련 파일 (다운로드 완료 시 Finder에서 보기)
    var fileURL: URL? = nil
    /// 좌측 아이콘 대신 그릴 값 (AI 사용량: 왼쪽 5시간 · 오른쪽 주간)
    var leadingValue: ActivityValue? = nil
    /// 시작 시각 (통화: 왼쪽에 통화 시간을 센다)
    var startDate: Date? = nil
    /// 커서가 노치 위에 있어도 표시 시간이 흐른다 (메뉴바 근처에서 끝나는 녹화 완료 알림 등)
    var ignoresHoverPause = false
}
