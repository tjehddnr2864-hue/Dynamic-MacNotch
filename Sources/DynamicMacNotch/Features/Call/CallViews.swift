import SwiftUI

/// 상대 이름의 머리글자 원 (전화번호면 사람 아이콘)
struct CallAvatar: View {
    var name: String
    var size: CGFloat

    private var initials: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first.isLetter else { return nil }
        // 한글 이름은 첫 글자, 영어 이름은 단어 머리글자 두 개
        if first.unicodeScalars.first.map({ $0.value >= 0xAC00 && $0.value <= 0xD7A3 }) == true { return String(first) }
        return trimmed.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.38)], startPoint: .top, endPoint: .bottom))
            if let initials {
                Text(initials).font(.system(size: size * 0.42, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.48)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
    }
}

/// 둥근 통화 버튼 (받기·거절·끊기·음소거)
struct CallCircleButton: View {
    var symbol: String
    var fill: Color
    var size: CGFloat = 36
    var iconColor: Color = .white
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 통화 시간 (1초마다 다시 그림, 통화 중에만 존재)
struct CallDurationText: View {
    var since: Date
    var font: Font

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            Text(Self.format(ctx.date.timeIntervalSince(since)))
                .font(font)
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 수신 카드 (노치 아래로 확장): 왼쪽 상대, 오른쪽 거절·받기.
/// 두 손가락으로 위로 올리면 거절하지 않고 작은 표시로 접힌다.
struct CallIncomingCard: View {
    @ObservedObject var monitor: CallMonitor
    var activity: NotchActivity
    var notchSize: CGSize

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchSize.height)
            HStack(spacing: 12) {
                CallAvatar(name: activity.title ?? "", size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: activity.title ?? T("전화", "Phone"), font: .systemFont(ofSize: 14, weight: .semibold), color: .white)
                        .frame(height: 18)
                    Text(activity.subtitle ?? "").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CallCircleButton(symbol: "phone.down.fill", fill: .red, help: T("거절", "Decline")) { monitor.decline() }
                CallCircleButton(symbol: "phone.fill", fill: .green, help: T("받기", "Accept")) { monitor.answer() }
            }
            .padding(.horizontal, 30)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 8)
        }
    }
}

/// 통화 팝업 (길게 눌러 확장): 왼쪽 상대 아이콘·이름·통화 시간, 오른쪽 음소거·끊기.
struct CallPage: View {
    @ObservedObject var monitor: CallMonitor

    var body: some View {
        if case .active(let name, let since, let muted) = monitor.state {
            HStack(spacing: 12) {
                CallAvatar(name: name, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(text: name.isEmpty ? T("통화 중", "On Call") : name,
                                font: .systemFont(ofSize: 15, weight: .semibold), color: .white)
                        .frame(height: 19)
                    HStack(spacing: 6) {
                        CallDurationText(since: since, font: .system(size: 12, weight: .medium))
                            .opacity(0.65)
                        if muted {
                            Label(T("음소거", "Muted"), systemImage: "mic.slash.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CallCircleButton(symbol: muted ? "mic.slash.fill" : "mic.fill",
                                 fill: muted ? Color.white.opacity(0.92) : Color.white.opacity(0.18), size: 40,
                                 iconColor: muted ? .black : .white,
                                 help: muted ? T("음소거 해제", "Unmute") : T("음소거", "Mute")) { monitor.toggleMute() }
                CallCircleButton(symbol: "phone.down.fill", fill: .red, size: 40, help: T("끊기", "End Call")) { monitor.hangUp() }
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "phone").font(.system(size: 20)).foregroundStyle(.white.opacity(0.5))
                Text(T("진행 중인 통화가 없습니다", "No active call")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}
