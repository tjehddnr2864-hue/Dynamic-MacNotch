import AppKit
import SwiftUI

/// 메뉴바 아이콘과 노치 우클릭 메뉴
extension AppDelegate {
    func setStatusItem(visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Dynamic MacNotch")
            item.menu = makeMenu()
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(T("설정…", "Settings…"), #selector(openSettings), key: ","))
        menu.addItem(item(T("권한 관리…", "Permissions…"), #selector(openPermissions)))
        menu.addItem(.separator())

        let demo = NSMenu()
        for d in PreviewID.menuItems {
            let mi = item(d.menuTitle, #selector(runDemo(_:)))
            mi.representedObject = d.rawValue
            demo.addItem(mi)
        }
        demo.addItem(.separator())
        let stop = item(T("모든 미리보기 중지", "Stop All Previews"), #selector(runDemo(_:)))
        stop.representedObject = PreviewID.stopAll.rawValue
        demo.addItem(stop)
        let demoItem = NSMenuItem(title: T("알림 미리보기", "Preview Alerts"), action: nil, keyEquivalent: "")
        demoItem.submenu = demo
        menu.addItem(demoItem)
        menu.addItem(item(T("홈 열기", "Open Home"), #selector(openHome)))
        // 두 손가락으로 쓸어 올려 상시 표시를 잠시 숨기는 것과 같다 (제목은 메뉴를 열 때 validateMenuItem이 정함)
        menu.addItem(item(T("콘텐츠 가리기", "Hide Content"), #selector(toggleContentHidden)))
        menu.addItem(.separator())
        menu.addItem(item(T("업데이트 확인…", "Check for Updates…"), #selector(checkForUpdates)))
        menu.addItem(item(T("Dynamic MacNotch 다시 시작", "Restart Dynamic MacNotch"), #selector(restart), key: "r"))
        menu.addItem(item(T("Dynamic MacNotch 종료", "Quit Dynamic MacNotch"), #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @objc private func openSettings() { showSettings() }
    @objc private func openPermissions() { showPermissions(onboarding: false) }
    @objc private func openHome() { vm.expand(page: .home) }

    @objc private func toggleContentHidden() {
        let hide = !center.persistentHidden
        withAnimation(hide ? vm.closeSpring : vm.openSpring) { center.setPersistentHidden(hide) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkForUpdates() { Updater.shared.check(userInitiated: true) }

    /// 오류·충돌이 의심될 때 사용자가 직접 앱을 다시 시작한다 (노치 우클릭 · 메뉴바 아이콘 메뉴).
    @objc func restart() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 현재 프로세스가 완전히 끝난 뒤 다시 연다 (어댑터 등 하위 프로세스도 함께 정리됨)
        // 경로는 셸 문자열에 끼워 넣지 않고 인자($1, $2)로 넘긴다 (경로에 따옴표·$ 등이 있어도 안전)
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; open \"$2\"",
                          "sh", String(ProcessInfo.processInfo.processIdentifier), path]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func runDemo(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let d = PreviewID(rawValue: raw) else { return }
        featurePreview.run(d)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// 메뉴를 열 때마다: 콘텐츠 가리기 ↔ 보이기, 상시 표시가 없으면 흐리게
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleContentHidden) else { return true }
        menuItem.title = center.persistentHidden ? T("콘텐츠 보이기", "Show Content") : T("콘텐츠 가리기", "Hide Content")
        return center.persistentHidden || center.hasPersistent
    }
}
