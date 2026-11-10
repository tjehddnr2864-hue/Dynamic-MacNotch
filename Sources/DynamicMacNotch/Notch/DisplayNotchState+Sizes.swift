import SwiftUI
import Combine

/// 노치와 확장 화면의 크기·모서리 계산
extension DisplayNotchState {
    /// 목표 크기 (애니메이션 전 최종값).
    var targetSize: CGSize {
        let n = notchSize
        switch state {
        case .idle:
            let bump: CGFloat = settings.hoverPreview && isHovering ? 1 : 0
            return CGSize(width: n.width + 14 * bump, height: n.height + 4 * bump)
        case .compact:
            let wing = NotchActivity.wing(for: displayed)
            return CGSize(width: n.width + wing * 2, height: n.height)
        case .detail:
            // 상세(확장) 알림: 컴팩트보다 좌우·아래로 조금 더 커진다. 스크린샷처럼 전용 높이가 있으면 넓게.
            if let extra = displayed?.detailHeight {
                return CGSize(width: max(n.width + 190, 390), height: n.height + extra)
            }
            return CGSize(width: max(n.width + 150, 330), height: n.height + 58)
        case .expanded:
            switch expandedPage {
            case .home:
                if homeOption == .usage || homeOption == .memo { return usageSize }
                if homeOption == .resource { return resourceSize }   // 메모도 AI 사용량과 같은 크기
                if homeOption == .chat { return shared.chatLarge ? chatSize : chatCompactSize }
                return homeOption == .camera && cameraOn ? cameraSize : expandedBaseSize
            case .activity(let kind):
                return popupSize(for: kind)
            }
        }
    }

    /// 상시 표시 항목을 길게 눌렀을 때 뜨는 독립 팝업 크기.
    func popupSize(for kind: ActivityKind) -> CGSize {
        let n = notchSize
        switch kind {
        case .media:
            // 참고 이미지: 노치보다 좌우로 넓고, 앨범아트·진행 바·조작 버튼 3줄
            return CGSize(width: max(n.width + 125, 300) + 2 * topRadius,
                          height: n.height + 152 + (mediaVolumeShown ? Self.mediaVolumeRowHeight : 0))
        case .timer:
            return CGSize(width: max(n.width + 60, 240) + 2 * topRadius, height: n.height + 120)
        case .call:
            // 음악 팝업과 같은 폭, 한 줄(상대·버튼)
            return CGSize(width: max(n.width + 125, 300) + 2 * topRadius, height: n.height + 84)
        case .download:
            // 음악 팝업과 같은 폭, 두 줄(아이콘·파일명 / 진행 바)에 맞춘 높이
            return CGSize(width: max(n.width + 125, 300) + 2 * topRadius, height: n.height + 104)
        case .recording:
            return CGSize(width: max(n.width + 60, 240) + 2 * topRadius, height: n.height + 110)
        case .aiUsage:
            return usageSize
        case .resource:
            return resourceSize
        case .update:
            // 업데이트 내용: AI 사용량과 같은 폭, 글이 들어가도록 더 높게
            return CGSize(width: usageSize.width, height: n.height + 6 + 190 + 22)
        default:
            return CGSize(width: max(n.width + 60, 240) + 2 * topRadius, height: n.height + 84)
        }
    }

    /// 기본 확장(길게누르기): 좌우로는 넓어지지 않고 노치 폭 그대로 아래로만 커진다.
    /// 도형의 위쪽 오목 모서리 폭(topRadius)만큼 양옆을 더해야 몸통이 노치 폭과 일치한다.
    /// 카메라를 켰을 때: 16:9 화면(약 356×200pt)이 들어가도록 좌우·아래로 더 커진다.
    var cameraSize: CGSize {
        let contentHeight: CGFloat = 200
        let contentWidth = (contentHeight * 16 / 9).rounded()
        return CGSize(width: contentWidth + 2 * (topRadius + 22), height: notchSize.height + 6 + contentHeight + 22)
    }

    /// 자원 사용량: 그래프 두 칸 + 네트워크 + 메모리 막대
    var resourceSize: CGSize {
        CGSize(width: usageSize.width, height: notchSize.height + 6 + 150 + 22)
    }

    /// AI 사용량: 서비스 세 줄(이름 · 5시간 · 주간)이 들어가도록 좌우·아래로 조금 더 넓게
    var usageSize: CGSize {
        CGSize(width: 300 + 2 * (topRadius + 22), height: notchSize.height + 6 + 124 + 22)
    }

    /// AI 채팅(대화): 답변을 읽을 수 있도록 AI 사용량보다 좌우·아래로 더 크게
    var chatSize: CGSize {
        CGSize(width: 340 + 2 * (topRadius + 22), height: notchSize.height + 6 + 200 + 22)
    }

    /// AI 채팅(입력·생각 중): 제목 줄 20 + 입력 줄 26 + 간격
    var chatCompactSize: CGSize {
        CGSize(width: chatSize.width, height: notchSize.height + 6 + 2 + 20 + 6 + 26 + shared.chatInputExtra + 22)
    }

    var expandedBaseSize: CGSize {
        // 기본 팝업(홈): 노치 폭보다 좌우 8% 넓게, 아래로 확장
        CGSize(width: (notchSize.width * 1.08).rounded() + 2 * topRadius, height: ((notchSize.height + 154) * 0.9).rounded())
    }

    /// 마우스가 반응해야 하는 영역 (확장 시 바깥 점 포함).
    var interactiveSize: CGSize {
        var size = targetSize
        if state == .expanded, expandedPage == .home || showsPersistentDots { size.height += Self.dotsAreaHeight }
        // 파일을 든 동안에는 노치 옆 막대까지 받는다 (좌우로 대칭)
        if fileDragOtherPage != nil {
            size.width += 2 * Self.fileDragBarZone
        }
        return size
    }

    /// 누르기 피드백까지 반영한 실제 표시 크기.
    var displaySize: CGSize {
        let size = targetSize
        if missionControlHidden, !reduceMotion {
            // 물리 노치가 있으면 그 폭까지(화면 테두리와 이어진다), 없으면 가운데로 모아 사라진다
            return CGSize(width: hasPhysicalNotch ? notchSize.width : 0, height: size.height)
        }
        guard state != .expanded else { return size }
        let p = 1 + 0.06 * max(pressProgress, forcePressure)
        return CGSize(width: size.width * p, height: size.height * p)
    }

    /// 위쪽(디스플레이 안으로 들어가는) 오목 모서리. 확장될수록 아래쪽 모서리와 함께 더 크게 휜다.
    var topRadius: CGFloat {
        switch state {
        case .idle, .compact: return 8
        case .detail: return 13
        case .expanded: return 16
        }
    }

    var bottomRadius: CGFloat {
        switch state {
        case .idle: return 10
        case .compact: return 12
        case .detail: return 30
        case .expanded: return 40
        }
    }
}
