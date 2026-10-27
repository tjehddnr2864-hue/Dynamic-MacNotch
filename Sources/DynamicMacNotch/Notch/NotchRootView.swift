import SwiftUI

/// 노치 패널의 루트 뷰. 검은 NotchShape가 상태에 따라 스프링으로 변형되고,
/// 그 안의 콘텐츠가 블러 전환으로 나타난다.
/// 3단계 기능 묶음 (뷰에서 기능별 화면을 그릴 때 사용).
struct NotchFeatures {
    let media: MediaController
    let screenshot: ScreenshotMonitor
    let recording: RecordingMonitor
    let tray: TrayStore
    let calendar: CalendarController
    let call: CallMonitor
}

struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel
    let timer: TimerController
    let features: NotchFeatures
    var openSettings: () -> Void

    var body: some View {
        let size = vm.displaySize
        let state = vm.state
        let shape = NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius)

        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                shape
                    .fill(Color.black)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(state == .expanded || state == .detail ? 0.4 : 0), radius: 14, y: 6)

                ZStack(alignment: .topLeading) {
                    content(state: state)
                        .frame(width: size.width, height: size.height, alignment: .top)
                    mediaArtLayer
                }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    // 사라지는 중인 이전 내용도 노치 도형 밖으로 삐져나오지 않게 한 묶음으로 잘라낸다.
                    .compositingGroup()
                    .clipShape(shape)
            }
            .modifier(ShakeEffect(animatableData: vm.shakeTrigger))
            .scaleEffect(x: vm.stretch.width, y: vm.stretch.height, anchor: .top)

            // 페이지 점: 확장된 노치 바깥 아래에 따로 떠 있다.
            if state == .expanded, vm.expandedPage == .home {
                PageDots(vm: vm)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.8), in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(vm.stateAnimation, value: state)
        .animation(vm.isRetracting ? vm.stateAnimation : (vm.animationOverride ?? vm.openSpring), value: vm.targetSize)
        .animation(vm.valueSpring, value: vm.center.displayed?.value)
        .environment(\.colorScheme, .dark)
    }

    /// 상태가 바뀌어도 사라지지 않는 단 하나의 앨범아트.
    /// 컴팩트(19pt) ↔ 상세 카드(36pt) ↔ 음악 팝업(50pt) 사이를 위치·크기만 바뀌며 이어서 움직인다.
    @ViewBuilder
    private var mediaArtLayer: some View {
        if let rect = vm.mediaArtRect, features.media.artwork != nil {
            let inMediaPage = vm.state == .expanded && vm.expandedPage == .activity(.media)
            // 확장된 음악 팝업에서만 곡이 바뀔 때 앨범아트가 돌아간다 (곡 변경 알림 팝업에서는 안 함)
            MediaArtView(media: features.media, size: rect.size, flipEnabled: inMediaPage && !vm.reduceMotion)
                // 좌우로 쓸어 곡을 넘길 때 팝업의 글자·아이콘과 함께 움직인다
                .offset(x: rect.minX + (inMediaPage ? vm.swipeOffset : 0), y: rect.minY)
                .allowsHitTesting(false)
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
        }
    }

    @ViewBuilder
    private func content(state: NotchState) -> some View {
        // 줄어드는 전환이면 제자리 등장, 커지는 전환이면 노치에서 바깥으로 퍼지며 등장
        let appear: AnyTransition = vm.isShrinking(to: vm.targetSize) ? .notchContentInPlace : .notchContent
        switch state {
        case .idle:
            Color.clear
        case .compact:
            if let a = vm.center.displayed {
                CompactActivityView(activity: a, notchSize: vm.notchSize)
                    .id(a.kind)
                    .transition(appear)
            }
        case .detail:
            if let a = vm.center.displayed {
                Group {
                    if a.kind == .screenshot {
                        ScreenshotCard(monitor: features.screenshot, notchSize: vm.notchSize)
                    } else if a.kind == .call {
                        CallIncomingCard(monitor: features.call, activity: a, notchSize: vm.notchSize)
                    } else {
                        DetailActivityView(activity: a, notchSize: vm.notchSize)
                    }
                }
                .id(a.id)
                .transition(appear)
            }
        case .expanded:
            ExpandedView(vm: vm, timer: timer, features: features, openSettings: openSettings)
                .transition(.notchContent)
        }
    }
}

/// 확장 상태: 노치 폭 그대로 아래로 커진 영역에 한 페이지씩 표시한다.
struct ExpandedView: View {
    @ObservedObject var vm: NotchViewModel
    let timer: TimerController
    let features: NotchFeatures
    var openSettings: () -> Void

    private var pages: HomePages {
        HomePages(
            camera: AnyView(CameraPage(vm: vm)),
            calendar: AnyView(CalendarPage(calendar: features.calendar)),
            tray: AnyView(TrayPage(store: features.tray, vm: vm))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: vm.notchSize.height)   // 카메라 영역
            Group {
                switch vm.expandedPage {
                case .home:
                    HomePager(vm: vm, timer: timer, pages: pages)
                case .activity(let kind):
                    activityPage(kind)
                        .offset(x: vm.swipeOffset)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 모든 확장 팝업 공통 여백 (음악 팝업 기준): 팝업 크기는 그대로, 글자·아이콘만 안쪽으로
            .padding(.horizontal, vm.topRadius + 22)
            .padding(.top, 6)
            .padding(.bottom, 22)
            .clipped()
        }
    }

    @ViewBuilder
    private func activityPage(_ kind: ActivityKind) -> some View {
        switch kind {
        case .timer:
            TimerPage(timer: timer)
        case .media:
            MediaPage(media: features.media, volumeShown: vm.mediaVolumeShown) { vm.toggleMediaVolume() }
        case .recording:
            RecordingPage(monitor: features.recording)
        case .call:
            CallPage(monitor: features.call)
        case .download:
            if let a = vm.center.displayed, a.kind == .download {
                DownloadPage(activity: a)
            }
        default:
            EmptyView()   // 알림은 확장 화면 대신 상세 카드로 표시한다
        }
    }
}
