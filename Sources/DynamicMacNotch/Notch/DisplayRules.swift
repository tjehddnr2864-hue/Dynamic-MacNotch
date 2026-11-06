import Foundation

/// 디스플레이 하나가 놓인 상황 (NotchHub가 정한다)
struct DisplayContext: Equatable {
    var uuid: String
    /// 주 디스플레이. 노치를 켰는지와 상관없다.
    var main: String
    /// 노치를 켠 디스플레이 전부
    var enabled: [String]
}

/// 중요한 알림 목록의 한 줄. 일회성 알림 하나를 가리키며, 통화·녹화만 상시 표시에도 적용된다.
enum CriticalAlert {
    /// 놓치면 안 되는 알림의 기본 구성
    static let defaults: Set<String> = ["call", "timer", "calendar", "batteryLow", "recording"]
    /// 상시 표시까지 따라가는 항목 (실행 중 타이머·다운로드 진행 등은 따라가지 않는다)
    static let persistentForm: [ActivityKind] = [.call, .recording]
    /// 설정 화면의 표시 순서
    static let all = ["call", "timer", "calendar", "batteryLow", "recording", "agent", "chat", "update", "download", "airdrop",
                      "screenshot", "media", "bluetooth", "network", "vpn", "focus", "battery", "hud"]

    static func id(of activity: NotchActivity) -> String {
        if activity.kind == .battery, activity.priority == ActivityPriority.batteryLow { return "batteryLow" }
        return activity.kind.rawValue
    }

    static func label(_ id: String) -> String {
        switch id {
        case "call": return T("통화", "Phone Calls")
        case "timer": return T("타이머 완료", "Timer Done")
        case "calendar": return T("일정 알림", "Event Alerts")
        case "batteryLow": return T("배터리 부족", "Low Battery")
        case "recording": return T("화면 녹화 중", "Screen Recording")
        case "agent": return T("AI 에이전트 작업 완료", "AI Agent Finished")
        case "chat": return T("AI 채팅 답변 완료", "AI Chat Answer Ready")
        case "update": return T("업데이트 완료", "Update Finished")
        case "download": return T("다운로드 결과", "Download Results")
        case "airdrop": return T("에어드랍 결과", "AirDrop Results")
        case "screenshot": return T("스크린샷 카드", "Screenshot Card")
        case "media": return T("곡 변경", "Track Changes")
        case "bluetooth": return T("블루투스", "Bluetooth")
        case "network": return T("네트워크", "Network")
        case "vpn": return "VPN"
        case "focus": return T("집중 모드", "Focus")
        case "battery": return T("충전 시작·완료", "Charging Started / Finished")
        case "hud": return T("음량·밝기·키보드 백라이트", "Volume, Brightness, Keyboard Backlight")
        default: return id
        }
    }
}

/// 어느 디스플레이에 무엇을 보일지 정하는 규칙. 화면에 의존하지 않는 순수 계산이다 (가이드라인 3.6).
struct DisplayRules {
    var content: [String: String]
    var fallbackToMain: Bool
    var alertScopeAll: Bool
    var criticalEnabled: Bool
    var critical: Set<String>

    /// 이 디스플레이의 선택. "주 디스플레이를 따름"은 한 번만 따라가므로 순환하지 않는다.
    /// 주 디스플레이가 "노치 없음"이면 그것을 따르지 않고 모든 항목을 보인다.
    func choice(_ ctx: DisplayContext) -> String {
        let own = content[ctx.uuid] ?? (ctx.uuid == ctx.main ? DisplayChoice.all : DisplayChoice.followMain)
        guard own == DisplayChoice.followMain else { return own }
        return mainChoice(ctx)
    }

    private func mainChoice(_ ctx: DisplayContext) -> String {
        let main = content[ctx.main] ?? DisplayChoice.all
        return main == DisplayChoice.followMain || main == DisplayChoice.none ? DisplayChoice.all : main
    }

    private static func kind(in choice: String) -> ActivityKind? {
        choice.hasPrefix("kind:") ? ActivityKind(rawValue: String(choice.dropFirst(5))) : nil
    }

    /// 일회성 알림이 이 디스플레이에 뜨는지
    func alertReaches(_ activity: NotchActivity, _ ctx: DisplayContext) -> Bool {
        guard ctx.enabled.contains(ctx.uuid) else { return false }
        if criticalEnabled, critical.contains(CriticalAlert.id(of: activity)) { return true }
        if alertScopeAll || !ctx.enabled.contains(ctx.main) { return true }
        return ctx.uuid == ctx.main
    }

    /// 이 디스플레이에 보일 상시 표시 항목 (active는 지금 활성인 항목)
    func persistentKinds(_ ctx: DisplayContext, active: Set<ActivityKind>) -> Set<ActivityKind> {
        var kinds: Set<ActivityKind>
        let choice = self.choice(ctx)
        switch choice {
        case DisplayChoice.notchOnly:
            kinds = []
        case DisplayChoice.all, DisplayChoice.none:
            kinds = active
        default:
            if let kind = Self.kind(in: choice), active.contains(kind) {
                kinds = [kind]
            } else if fallbackToMain {
                kinds = mainResult(ctx, active: active)   // 선택한 항목이 비활성: 주 디스플레이의 결과를 한 번만 가져온다
            } else {
                kinds = []
            }
        }
        if criticalEnabled {
            for kind in CriticalAlert.persistentForm where active.contains(kind) && critical.contains(kind.rawValue) {
                kinds.insert(kind)
            }
        }
        return kinds
    }

    /// 주 디스플레이가 자기 선택으로 보이는 항목 (대체는 하지 않는다)
    private func mainResult(_ ctx: DisplayContext, active: Set<ActivityKind>) -> Set<ActivityKind> {
        let choice = mainChoice(ctx)
        if choice == DisplayChoice.all { return active }
        if let kind = Self.kind(in: choice), active.contains(kind) { return [kind] }
        return []
    }
}
