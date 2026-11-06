import AppKit
import SwiftUI

/// 노치를 눌렀을 때: 길게 누르기와 짧은 클릭
extension AppDelegate {
    /// 길게 누르면 자기 확장 화면이 열리는 활동 (나머지 알림은 확장 화면이 없다)
    private static let pagedKinds: Set<ActivityKind> = [.timer, .media, .recording, .call, .download, .aiUsage]

    /// 길게누르기·누름 반응이 있는지: 상세로 이미 떠 있는 알림과 HUD는 클릭만 받는다.
    func hasLongPressAction(_ activity: NotchActivity?) -> Bool {
        guard let a = activity else { return true }   // 빈 노치: 홈 열기
        if Self.pagedKinds.contains(a.kind) { return true }
        if [.hud, .lock].contains(a.kind) { return false }
        if center.transient?.id == a.id { return !center.showingDetail }
        return true
    }

    /// 길게누르기: 확장 화면을 열면 true. 알림은 확장 화면 대신 상세 카드로 바꾼다.
    func longPress(_ activity: NotchActivity?) -> Bool {
        guard let a = activity, !Self.pagedKinds.contains(a.kind) else { return true }
        guard hasLongPressAction(a) else { return false }
        // 상시 표시 항목(핫스팟·집중 모드 등): 팝업을 열고 다른 상시 항목을 점·스와이프로 넘겨 본다
        if center.transient?.id != a.id, center.persistentKinds.contains(a.kind) { return true }
        Haptics.perform()
        if center.transient?.id == a.id {
            center.promoteToDetail()   // 컴팩트 알림 → 상세 카드
        } else {
            // 상시 표시(핫스팟·집중 모드 등)는 같은 내용을 상세 카드로 잠깐 보여 준다
            var detail = a
            detail.id = UUID()
            detail.presentation = .detail
            detail.duration = nil
            center.post(detail)
        }
        return false
    }

    /// 알림·활동을 길게 눌러 연 확장 노치는 그 알림이 사라지면 자동으로 닫는다.
    /// (타이머·배터리·음악 화면은 알림이 없어도 내용이 있으므로 그대로 둔다)
    func collapseIfActivityGone() {
        guard vm.isExpanded, case .activity(let kind) = vm.expandedPage,
              ![.timer, .media, .update].contains(kind) else { return }
        let stillShown = center.transient?.kind == kind || center.persistentKinds.contains(kind)
            || (kind == .recording && (recording.startedAt != nil || recording.finished != nil))   // 녹화 중·완료 화면 유지
        if !stillShown { vm.collapse() }
    }

    func handleClick(_ activity: NotchActivity?, leftSide: Bool, on vm: DisplayNotchState) {
        guard let activity else { return }
        switch activity.kind {
        case .battery:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
        case .timer:
            vm.expand(page: .activity(.timer))
        case .media:
            media.openSourceApp()
        case .download:
            downloads.revealLastCompleted()
        case .recording:
            // 녹화 중 노치 왼쪽(녹화 시간·아이콘)을 누르면 정지·저장, 오른쪽은 녹화 화면 열기
            // 끝난 뒤의 '저장됨' 알림을 누르면 저장된 파일을 Finder에서 보여 준다
            if recording.startedAt == nil { recording.revealFinished(); center.dismissTransient() }
            else if leftSide { recording.stop() } else { vm.expand(page: .activity(.recording)) }
        case .call:
            // 접어 둔 수신 표시를 누르면 다시 카드로, 통화 중이면 통화 팝업
            if case .incoming = call.state { call.expandIncoming() } else { vm.expand(page: .activity(.call)) }
        case .airdrop:
            if let url = activity.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .screenshot:
            break   // 카드 안 버튼으로 조작
        case .chat:
            // 답변 완료 알림을 누르면 그 채팅으로
            chat.openAnswerNext()
            vm.openChat()
            center.dismissTransient()
        case .update:
            // 업데이트 완료 알림(오른쪽 문서 아이콘)을 누르면 업데이트 내용
            vm.expand(page: .activity(.update))
            center.dismissTransient()
        case .agent:
            // Claude Code·Codex 작업 완료: 그 에이전트가 돌던 앱을 연다
            AgentNotify.open(activity.targetApp)
            center.dismissTransient()
        default:
            center.dismissTransient()
        }
    }
}
