import SwiftUI

/// 권한 관리 창 (가이드라인 6장). 최초 실행 시에는 환영 → 권한 → 완료 순서의 온보딩으로 열린다.
struct PermissionsView: View {
    @ObservedObject var manager = PermissionsManager.shared
    @ObservedObject var settings = AppSettings.shared
    var onboarding: Bool
    /// 설정 창 안에 넣을 때: 고정 크기·닫기 버튼 없이
    var embedded = false
    var close: () -> Void

    private let stepState = State(initialValue: 0)
    private var step: Int {
        get { stepState.wrappedValue }
        nonmutating set { stepState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if onboarding && step == 0 {
                welcome
            } else if onboarding && step == 2 {
                finished
            } else {
                permissionList
            }
        }
        .frame(width: embedded ? nil : 560, height: embedded ? nil : 640)
        .onAppear { manager.startAutoRefresh() }
        .onDisappear { manager.stopAutoRefresh() }
    }

    // MARK: - 환영

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                NotchShape(topRadius: 10, bottomRadius: 26)
                    .fill(Color.black)
                    .frame(width: 260, height: 70)
                HStack(spacing: 150) {
                    Image(systemName: "bolt.fill").foregroundStyle(.green)
                    Text("82%").foregroundStyle(.white).font(.system(size: 14, weight: .semibold, design: .rounded))
                }
            }
            Text(T("Dynamic MacNotch에 오신 것을 환영합니다", "Welcome to Dynamic MacNotch"))
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 10) {
                tip("hand.tap", T("노치를 길게 누르면 홈(카메라·타이머·일정·트레이)이 열립니다.", "Long-press the notch to open Home (camera, timer, events, tray)."))
                tip("hand.point.up.braille", T("포스터치 트랙패드에서는 깊게 눌러 바로 열 수 있습니다.", "On a Force Touch trackpad, press firmly to open it right away."))
                tip("cursorarrow.click.2", T("노치를 우클릭하면 설정과 알림 미리보기 메뉴가 나옵니다.", "Right-click the notch for Settings and alert previews."))
                tip("hand.draw", T("열린 상태에서 두 손가락으로 위로 쓸면 닫힙니다.", "When open, swipe up with two fingers to close."))
            }
            .padding(.horizontal, 60)
            Spacer()
            Button(T("다음", "Next")) { withAnimation { step = 1 } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 28)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 권한 목록

    private var permissionList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if !embedded {   // 설정 창 안에서는 페이지 제목이 따로 있다
                        Text(T("권한 관리", "Permissions")).font(.title2.bold())
                    }
                    Spacer()
                    Text(T("\(manager.grantedCount)/\(PermissionKind.allCases.count) 허용됨", "\(manager.grantedCount)/\(PermissionKind.allCases.count) allowed"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: Double(manager.grantedCount), total: Double(PermissionKind.allCases.count))
                Text(T("필수 권한이 없으면 해당 기능만 꺼지고 나머지는 동작합니다. 선택 권한은 나중에 허용해도 됩니다.", "Without a required permission, only that feature is turned off and everything else keeps working. Optional permissions can be allowed later."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(PermissionTier.allCases, id: \.self) { tier in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tier.label).font(.headline).foregroundStyle(.secondary)
                            ForEach(PermissionKind.allCases.filter { $0.tier == tier }) { kind in
                                PermissionRow(kind: kind, status: manager.status(kind), manager: manager)
                            }
                        }
                    }
                    Text(T("앱을 새 버전으로 바꾼 뒤 손쉬운 사용·입력 모니터링이 허용돼 있는데도 동작하지 않으면, 시스템 설정에서 Dynamic MacNotch 항목을 지우고(−) 다시 허용하세요.", "If Accessibility or Input Monitoring stops working after updating the app even though it is allowed, remove Dynamic MacNotch from that list in System Settings (−) and allow it again."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }

            if !embedded {
            Divider()

            HStack {
                if onboarding {
                    Button(T("이전", "Back")) { withAnimation { step = 0 } }
                }
                Spacer()
                Button(onboarding ? T("다음", "Next") : T("닫기", "Close")) {
                    if onboarding { withAnimation { step = 2 } } else { close() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            }
        }
    }

    // MARK: - 완료

    private var finished: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.green)
            Text(T("준비 완료", "All Set")).font(.title2.bold())
            Text(T("권한은 노치 우클릭 메뉴나 메뉴바 아이콘의 '권한 관리'에서 언제든 바꿀 수 있습니다.", "You can change permissions anytime from 'Permissions' in the notch's right-click menu or the menu bar icon."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 60)
            Spacer()
            Button(T("시작하기", "Get Started")) {
                settings.onboardingDone = true
                close()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 28)
        }
    }
}

struct PermissionRow: View {
    var kind: PermissionKind
    var status: PermissionStatus
    var manager: PermissionsManager
    private let requestedState = State(initialValue: false)
    private var requested: Bool {
        get { requestedState.wrappedValue }
        nonmutating set { requestedState.wrappedValue = newValue }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.body.weight(.medium))
                Text(kind.purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            badge
            if status == .granted {
                if kind.needsRelaunch && requested {
                    Button(T("앱 다시 시작", "Restart App")) { manager.relaunch() }
                } else if kind == .loginItem {
                    Button(T("끄기", "Off")) { manager.request(kind) }
                }
            } else {
                Button(status == .denied ? T("설정 열기", "Open Settings") : T("허용", "Allow")) {
                    requested = true
                    manager.request(kind)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var badge: some View {
        let color: Color = switch status {
        case .granted: .green
        case .denied: .red
        case .needsAppRunning, .unknown: .gray
        case .notDetermined: .orange
        }
        return Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
