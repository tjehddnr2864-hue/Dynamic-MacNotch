import AppKit
import SwiftUI
import Combine

/// 잠금화면 (가이드라인 5.12·5.13).
/// - 잠기면 노치에 자물쇠, 풀리면 고리가 열리는 애니메이션 뒤 원래 상태로.
/// - 음악이 재생 중이면 잠금화면에 미디어 카드(노치 아님)를 띄우고, 앨범아트를 누르면 전체화면 플레이어 + 가사.
/// - 잠금화면 위에 그리려면 SkyLight 전용 Space로 창을 옮긴다. 실패하면 잠금 해제 애니메이션만 보인다.
final class LockScreenManager: ObservableObject {
    @Published private(set) var isLocked = false

    private let center: ActivityCenter
    private let vm: NotchViewModel
    private let media: MediaController
    let lyrics = LyricsProvider()
    let playerState = LockPlayerState()
    private let settings = AppSettings.shared
    private var playerWindow: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    /// 개발용 미리보기: 실제로 잠그지 않고 일반 화면에서 잠금 상태를 흉내 낸다.
    private var preview = false
    /// 화면 보호기가 돌고 있는지. 이 동안에는 잠금화면 음악 위젯을 띄우지 않는다.
    private(set) var screenSaverActive = false
    /// 숨김 애니메이션이 끝나기 전에 다시 보이게 되면 이전 숨김 완료 처리를 무시한다.
    private var playerHideToken = 0

    /// 잠금화면 노치 창 보이기/숨기기, 미리 준비 (AppDelegate가 NotchController에 연결)
    var setLockNotchVisible: ((Bool) -> Void)?
    /// 평소 노치 창 숨기기/보이기 (숨김, 서서히)
    var setMainNotchHidden: ((Bool, Bool) -> Void)?
    /// 잠금화면 전용 노치 창을 쓸 수 있는지 (SkyLight 이동 성공 여부)
    var lockNotchAvailable: (() -> Bool)?
    var prepareLockNotch: (() -> Void)?

    init(center: ActivityCenter, vm: NotchViewModel, media: MediaController) {
        self.center = center
        self.vm = vm
        self.media = media
    }

    /// 노치를 강제로 다시 그리는 처리기 (AppDelegate가 연결)
    var refreshNotch: (() -> Void)?

    func start() {
        // 잠기는 순간 옮기면 첫 프레임이 늦어 노치가 덜 펼쳐진 채 보일 수 있어, 앱 시작 때 미리 준비한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.settings.lockNotchEnabled else { return }
            self.prepareLockNotch?()
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.lock(preview: false)
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.unlock()
        }
        // 화면 보호기: 시작하면 음악 위젯을 숨기고, 끝나면(아직 잠겨 있으면) 다시 보인다.
        dnc.addObserver(forName: .init("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            self?.setScreenSaver(active: true)
        }
        for name in ["com.apple.screensaver.willstop", "com.apple.screensaver.didstop"] {
            dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                self?.setScreenSaver(active: false)
            }
        }
        // 잠금 중 재생 상태가 바뀌면 카드를 띄우거나 숨긴다.
        media.$nowPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] np in
                guard let self, self.isLocked else { return }
                self.updatePlayerVisibility(hasMedia: np != nil)
                if self.playerState.isFull { self.lyrics.load(for: np) }
            }
            .store(in: &cancellables)
    }

    // MARK: - 잠금 / 해제

    /// macOS 잠금/해제 전환 애니메이션(화면 전체가 움직임)이 끝날 때까지 기다리는 시간
    private static let systemTransition: TimeInterval = 1.2
    private var swapWork: DispatchWorkItem?

    /// 잠금: 데스크탑과 함께 움직이는 평소 노치는 즉시 숨기고,
    /// 잠금화면 전용 Space에 있는(전환 애니메이션과 무관한) 노치 창만 보인다.
    func lock(preview: Bool) {
        guard !isLocked else { return }
        self.preview = preview
        isLocked = true
        swapWork?.cancel()
        vm.collapse()
        let independent = !preview && settings.lockNotchEnabled && (lockNotchAvailable?() ?? false)
        if !preview { setMainNotchHidden?(true, false) }
        // 화면 보호기 상태는 잠글 때 실제 상태로 다시 맞춘다 (끝남 알림을 놓쳐 '실행 중'으로 남는 일 방지)
        screenSaverActive = !preview && Self.screenSaverRunning()
        if settings.lockNotchEnabled {
            center.lockActivity = NotchActivity(kind: .lock, priority: ActivityPriority.lock,
                                                symbol: "lock", tint: .white, value: .none, wing: 38)
        }
        if independent { setLockNotchVisible?(true) }
        // 잠금 전환 중에는 가려진 창의 화면 갱신이 멈출 수 있어, 잠금화면이 뜬 뒤 다시 그리게 한다.
        for delay in [0.3, 0.8, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isLocked else { return }
                self.refreshNotch?()
            }
        }
        updatePlayerVisibility(hasMedia: media.nowPlaying != nil)
    }

    /// 해제: 자물쇠 열림은 독립된 잠금화면 노치 창에서만 보이고(데스크탑 전환과 함께 움직이지 않음),
    /// macOS 전환이 끝난 뒤 평소 노치로 조용히 바꾼다. 독립 창을 못 쓰면 애니메이션 없이 전환 뒤에 나타난다.
    func unlock() {
        guard isLocked else { return }
        isLocked = false
        screenSaverActive = false
        hidePlayer()
        let independent = !preview && settings.lockNotchEnabled && (lockNotchAvailable?() ?? false)

        if preview || independent, center.lockActivity != nil {
            center.lockActivity?.symbol = "lock.open"
            Haptics.perform()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, !self.isLocked else { return }
                withAnimation(self.vm.closeSpring) { self.center.lockActivity = nil }
            }
        } else {
            center.lockActivity = nil
        }

        guard !preview else { return }
        // 두 창이 같은 내용을 그리는 시점(전환 완료 후)에 바꿔치기한다.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isLocked else { return }
            // 평소 노치를 먼저 그대로(페이드 없이) 보이고, 다음 프레임에 잠금화면 노치를 치운다 → 깜빡임 없음
            self.setMainNotchHidden?(false, false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard !self.isLocked else { return }
                self.setLockNotchVisible?(false)
            }
        }
        swapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.systemTransition, execute: work)
    }

    // MARK: - 화면 보호기

    func setScreenSaver(active: Bool) {
        guard screenSaverActive != active else { return }
        screenSaverActive = active
        guard isLocked else { return }
        updatePlayerVisibility(hasMedia: media.nowPlaying != nil)
    }

    /// 알림을 놓쳤을 때를 대비해 화면 보호기 프로세스가 떠 있는지도 확인한다.
    private static func screenSaverRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" }
    }

    // MARK: - 미디어 위젯

    private func updatePlayerVisibility(hasMedia: Bool) {
        if hasMedia, settings.lockMediaWidget, !screenSaverActive {
            showPlayer()
        } else {
            hidePlayer()
        }
    }

    private var screen: NSScreen? {
        NotchGeometry.targetScreen(for: settings.displayTarget) ?? NSScreen.main
    }

    private func showPlayer() {
        guard let screen else { return }
        let frame = screen.frame
        let cardSize = CGSize(width: 380, height: 208)
        // 하단 배치: 잠금화면의 프로필 사진·이름·암호 입력란(화면 아래 약 290pt 구간) 바로 위에 겹치지 않게 놓는다.
        let loginArea: CGFloat = 300
        let top = frame.height - loginArea - cardSize.height
        playerState.cardRect = CGRect(x: (frame.width - cardSize.width) / 2, y: top,
                                      width: cardSize.width, height: cardSize.height)

        playerHideToken += 1
        if playerWindow == nil {
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            playerWindow = panel
        }
        guard let panel = playerWindow else { return }
        // 새 창에는 빈 기본 뷰가 들어 있으므로 nil 여부가 아니라 위젯 뷰인지로 판단한다.
        if !(panel.contentView is NSHostingView<LockPlayerView>) {
            // 투명한 부분은 클릭이 통과한다 (잠금화면 암호 입력 방해 안 함)
            // 숨길 때 내용을 해제하므로(메모리) 다시 보일 때 새로 만든다 (화면 보호기가 끝난 뒤 등)
            let view = LockPlayerView(media: media, lyrics: lyrics, state: playerState) { [weak self] in
                self?.closeFull()
            }
            panel.contentView = NSHostingView(rootView: view)
        }
        panel.setFrame(frame, display: true)
        let wasVisible = panel.isVisible
        panel.alphaValue = wasVisible ? 1 : 0
        panel.orderFrontRegardless()
        if !preview { SkyLight.moveToLockScreenSpace(panel) }
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hidePlayer() {
        guard let panel = playerWindow, panel.isVisible else { return }
        playerState.isFull = false
        playerHideToken += 1
        let token = playerHideToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // 그사이 다시 보이게 됐으면 아무것도 하지 않는다
            guard let self, self.playerHideToken == token else { return }
            panel.orderOut(nil)
            // 전체화면 크기의 투명 창(레티나 기준 수십 MB 버퍼)을 잠금 해제 후에도 들고 있지 않게 해제한다.
            panel.contentView = nil
            if !self.isLocked { self.playerWindow = nil }
            MemoryTrim.soon()
        })
    }

    func closeFull() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { playerState.isFull = false }
    }

    // MARK: - 개발용

    func openFull() {
        lyrics.load(for: media.nowPlaying)
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { playerState.isFull = true }
    }
}
