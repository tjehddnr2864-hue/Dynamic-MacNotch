import AppKit
import SwiftUI
import ApplicationServices

/// 설정·권한 창 전용 도우미 프로세스.
/// 본 앱이 `--helper=settings|permissions|onboarding`으로 같은 실행 파일을 띄우고,
/// 창이 모두 닫히면 프로세스가 끝나 그 메모리(SwiftUI 폼, 시스템 글꼴·아이콘 캐시 약 20MB)가 통째로 반환된다.
/// 설정 변경은 AppSettings가, 미리보기·재시작은 디버그 채널로 본 앱에 전달한다.
enum Helper {
    static let commandNotification = Notification.Name("com.dynamicmacnotch.app.command")
    static let helperNotification = Notification.Name("com.dynamicmacnotch.app.helper")

    /// 본 앱에 명령 보내기 (미리보기, 재시작)
    static func sendToMain(_ command: String) {
        DistributedNotificationCenter.default().postNotificationName(commandNotification, object: command,
                                                                     userInfo: nil, deliverImmediately: true)
    }

    static func mode(from arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix("--helper=") }.map { String($0.dropFirst("--helper=".count)) }
    }
}

/// 설정 창의 HUD 상태 표시용 (도우미 프로세스에서는 손쉬운 사용 허용 여부로 판단)
final class HUDStatus: ObservableObject {
    @Published private(set) var active = AXIsProcessTrusted()
    private var timer: Timer?

    init() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            let v = AXIsProcessTrusted()
            if self?.active != v { self?.active = v }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }
}

final class HelperDelegate: NSObject, NSApplicationDelegate {
    private let mode: String
    private var settingsWindow: NSWindow?
    private var permissionsWindow: NSWindow?
    private let hud = HUDStatus()

    init(mode: String) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        open(mode)
        // 본 앱이 다시 '설정 열기'를 요청하면 새 프로세스를 띄우지 않고 이 창을 앞으로 가져온다.
        DistributedNotificationCenter.default().addObserver(forName: Helper.helperNotification, object: nil,
                                                            queue: .main) { [weak self] n in
            guard let self, let command = n.object as? String else { return }
            if command == "close" {
                NSApp.terminate(nil)
            } else {
                self.open(command)
            }
        }
        // 본 앱이 끝나면 도우미도 끝낸다.
        let parent = getppid()
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        parentWatch = source
    }

    private var parentWatch: DispatchSourceProcess?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func open(_ mode: String) {
        switch mode {
        case "permissions": showPermissions(onboarding: false)
        case "onboarding": showPermissions(onboarding: true)
        default: showSettings()
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(hud: hud, preview: { which in Helper.sendToMain("preview:" + which) })
            let window = makeWindow(title: T("Dynamic MacNotch 설정", "Dynamic MacNotch Settings"), content: view)
            // 유리 창: 제목 막대를 숨기고 내용이 창 전체를 채워, 뒤 화면이 비치게 한다.
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            settingsWindow = window
        }
        present(settingsWindow)
    }

    private func showPermissions(onboarding: Bool) {
        if permissionsWindow == nil {
            let view = PermissionsView(onboarding: onboarding) { [weak self] in self?.permissionsWindow?.close() }
            permissionsWindow = makeWindow(title: onboarding ? T("Dynamic MacNotch 시작하기", "Welcome to Dynamic MacNotch") : T("권한 관리", "Permissions"), content: view)
        }
        present(permissionsWindow)
    }

    private func makeWindow<V: View>(title: String, content: V) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [weak self, weak window] _ in
            if self?.settingsWindow === window { self?.settingsWindow = nil }
            if self?.permissionsWindow === window { self?.permissionsWindow = nil }
        }
        // 마우스가 있는 화면 가운데에 띄운다.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let v = screen.visibleFrame, size = window.frame.size
            window.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2))
        }
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
