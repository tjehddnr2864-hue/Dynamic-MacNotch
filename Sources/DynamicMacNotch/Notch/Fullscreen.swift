import AppKit

/// 디스플레이마다 전체 화면 앱이 떠 있는지 (설정 → 디스플레이 → 전체 화면에서 컴팩트로).
///
/// ① 창 서버가 디스플레이마다 지금 공간의 종류를 알려 준다(비공개 SkyLight, 이 앱은 잠금화면·Mission Control에도 씀).
///    전체 화면 공간은 종류가 4다. 디스플레이 이름은 UUID라 디스플레이별로 정확하다.
/// ② 그 함수가 없거나 '디스플레이마다 별도 공간'이 꺼져 이름이 "Main" 하나뿐이면 창으로 짐작한다:
///    화면 폭을 다 덮고 화면 아래 끝(Dock 자리)까지 내려온 일반 창. (전체 화면에서도 메뉴 막대 창은 목록에 그대로 있어
///    메뉴 막대로는 가를 수 없다 — 2026-11 실측. Dock을 자동으로 숨기면 최대화 창을 전체 화면으로 볼 수 있다.)
/// 공간·앱·화면 구성이 바뀔 때만 읽는다.
enum Fullscreen {
    struct Window {
        var layer: Int
        var owner: String
        var name: String
        var frame: CGRect   // CG 좌표 (주 화면 왼쪽 위가 원점, 아래로 +)
    }

    /// 전체 화면인 디스플레이 (screens: uuid와 CG 좌표 화면 사각형)
    static func displays(windows: [Window], screens: [(uuid: String, frame: CGRect)], ownName: String) -> Set<String> {
        var result = Set<String>()
        for screen in screens {
            let s = screen.frame
            let covered = windows.contains { w in
                w.layer == 0 && w.owner != ownName
                    && abs(w.frame.minX - s.minX) < 2 && abs(w.frame.width - s.width) < 2
                    && abs(w.frame.maxY - s.maxY) < 2 && w.frame.height >= s.height * 0.8
            }
            if covered { result.insert(screen.uuid) }
        }
        return result
    }

    /// ① 공간 종류로 (디스플레이 UUID → 전체 화면인지). 쓸 수 없으면 nil.
    static func fromSpaces(_ spaces: [[String: Any]], connected: [String]) -> Set<String>? {
        guard !spaces.isEmpty else { return nil }
        var result = Set<String>()
        for d in spaces {
            guard let id = d["Display Identifier"] as? String, connected.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame })
            else { return nil }   // "Main"처럼 디스플레이를 가리키지 않으면 창으로 짐작한다
            if ((d["Current Space"] as? [String: Any])?["type"] as? Int) == 4 {
                result.insert(connected.first { $0.caseInsensitiveCompare(id) == .orderedSame } ?? id)
            }
        }
        return result
    }

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let spacesFunctions: (ConnectionFn, SpacesFn)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let c = dlsym(h, "SLSMainConnectionID") ?? dlsym(h, "CGSMainConnectionID"),
              let s = dlsym(h, "SLSCopyManagedDisplaySpaces") ?? dlsym(h, "CGSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(c, to: ConnectionFn.self), unsafeBitCast(s, to: SpacesFn.self))
    }()

    /// 지금 화면에서 읽는다
    static func current() -> Set<String> {
        let connected = NSScreen.screens.compactMap(Displays.uuid(of:))
        if let (connection, copySpaces) = spacesFunctions,
           let spaces = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]],
           let result = fromSpaces(spaces, connected: connected) {
            return result
        }
        return fromWindows()
    }

    private static func fromWindows() -> Set<String> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let windows: [Window] = list.compactMap { w in
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return Window(layer: w[kCGWindowLayer as String] as? Int ?? 0,
                          owner: w[kCGWindowOwnerName as String] as? String ?? "",
                          name: w[kCGWindowName as String] as? String ?? "",
                          frame: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
        }
        // NSScreen(왼쪽 아래 원점) → CG(주 화면 왼쪽 위 원점)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens: [(uuid: String, frame: CGRect)] = NSScreen.screens.compactMap { screen in
            guard let uuid = Displays.uuid(of: screen) else { return nil }
            let f = screen.frame
            return (uuid, CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height))
        }
        let own = ProcessInfo.processInfo.processName
        return displays(windows: windows, screens: screens, ownName: own)
    }
}
