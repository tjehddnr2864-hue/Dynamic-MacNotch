import AppKit

/// 연결된 디스플레이 하나의 정보. 설정 저장에는 UUID만 쓴다 (이름은 비어 있거나 겹칠 수 있다).
struct DisplayInfo: Identifiable, Equatable {
    let uuid: String
    let name: String
    let size: CGSize
    let isMain: Bool
    let isBuiltIn: Bool
    let hasNotch: Bool
    var id: String { uuid }

    /// 설정 목록에 보일 글: 이름 · 1800×1125 · 주 디스플레이
    var label: String {
        var parts = [name, "\(Int(size.width))×\(Int(size.height))"]
        if isMain { parts.append(T("주 디스플레이", "Main Display")) }
        return parts.joined(separator: " · ")
    }
}

/// 디스플레이별 상시 표시 선택 (`displayContent`의 값)
enum DisplayChoice {
    static let all = "all"
    static let notchOnly = "notchOnly"
    static let none = "none"
    static let followMain = "followMain"
    static func kind(_ key: String) -> String { "kind:" + key }
}

enum Displays {
    /// `notchDisplays` 값: 디스플레이 하나
    static func selection(uuid: String) -> String { "one:" + uuid }

    static func uuid(selection: String) -> String? {
        selection.hasPrefix("one:") ? String(selection.dropFirst(4)) : nil
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func uuid(of screen: NSScreen) -> String? {
        guard let id = displayID(of: screen), let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// 다른 화면을 복제 중인 디스플레이는 빼고, 실제로 내용을 그리는 화면만 (첫 번째가 주 디스플레이)
    static var screens: [NSScreen] {
        NSScreen.screens.filter { screen in
            guard let id = displayID(of: screen) else { return true }
            return CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay
        }
    }

    /// 노치를 켠 디스플레이의 UUID (주 디스플레이가 먼저). 비는 일이 없도록, 전부 "노치 없음"이면 주 디스플레이를 켠다.
    static func enabledUUIDs(selection: String, content: [String: String], connected: [String]) -> [String] {
        guard let main = connected.first else { return [] }
        let chosen: [String]
        switch selection {
        case "all": chosen = connected
        case "main": chosen = [main]
        default:
            chosen = uuid(selection: selection).flatMap { connected.contains($0) ? [$0] : nil } ?? []
        }
        let enabled = chosen.filter { content[$0] != DisplayChoice.none }
        return enabled.isEmpty ? [main] : enabled
    }

    /// 설정 값에 해당하는 화면. 선택한 디스플레이가 연결되어 있지 않으면 노치 있는 화면 → 주 디스플레이로 대신한다.
    /// 설정 값은 바꾸지 않으므로 다시 연결되면 원래대로 돌아간다.
    static func screen(for selection: String) -> NSScreen? {
        let list = screens
        if let uuid = uuid(selection: selection), let match = list.first(where: { self.uuid(of: $0) == uuid }) {
            return match
        }
        if selection == "main" || selection == "all" { return list.first ?? NSScreen.main }
        return list.first { $0.safeAreaInsets.top > 0 } ?? list.first ?? NSScreen.main
    }

    /// 연결된 디스플레이 목록 (설정 화면용). 이름이 없으면 종류로 부르고, 겹치면 번호를 붙인다.
    static func all() -> [DisplayInfo] {
        let list = screens
        let names: [String] = list.map { screen in
            let name = screen.localizedName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
            let builtIn = displayID(of: screen).map { CGDisplayIsBuiltin($0) != 0 } ?? false
            return builtIn ? T("내장 디스플레이", "Built-in Display") : T("외부 디스플레이", "External Display")
        }
        var seen: [String: Int] = [:]
        return list.enumerated().compactMap { index, screen in
            guard let uuid = uuid(of: screen) else { return nil }
            let base = names[index]
            seen[base, default: 0] += 1
            let name = names.filter { $0 == base }.count > 1 ? "\(base) (\(seen[base] ?? 1))" : base
            return DisplayInfo(uuid: uuid, name: name, size: screen.frame.size, isMain: index == 0,
                               isBuiltIn: displayID(of: screen).map { CGDisplayIsBuiltin($0) != 0 } ?? false,
                               hasNotch: screen.safeAreaInsets.top > 0)
        }
    }
}
