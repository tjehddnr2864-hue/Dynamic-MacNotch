import SwiftUI
import Intents

/// 집중 모드 켜짐/꺼짐 감지 (가이드라인 5.5).
/// ① 전체 디스크 접근이 있으면 DoNotDisturb DB에서 모드 이름·아이콘·색을 읽고,
/// ② 없으면 INFocusStatusCenter로 켜짐/꺼짐만 판단한다.
final class FocusMonitor {
    struct Mode: Equatable {
        var id: String
        var name: String
        var symbol: String
        var tint: Color
    }

    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private var timer: Timer?
    private var current: Mode?
    private var initialized = false

    private static let dbURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/DoNotDisturb/DB")

    init(center: ActivityCenter) {
        self.center = center
    }

    func start() {
        poll()
        // 집중 모드 DB 폴더의 변경을 감시한다 (파일이 새로 쓰일 때만 깨어남, idle CPU 0).
        // 폴더를 읽을 수 없으면(전체 디스크 접근 없음) 가벼운 INFocusStatusCenter 확인만 5초마다 한다.
        if !watchDatabase() {
            let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingPoll: DispatchWorkItem?

    /// 폴더(파일 교체)와 Assertions.json 자체(제자리 쓰기)를 함께 감시한다.
    private func watchDatabase() -> Bool {
        guard let dir = makeSource(Self.dbURL.path) else { return false }
        dirSource = dir
        watchAssertionsFile()
        return true
    }

    private func watchAssertionsFile() {
        fileSource?.cancel()
        fileSource = makeSource(Self.dbURL.appendingPathComponent("Assertions.json").path)
    }

    private func makeSource(_ path: String) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete],
                                                            queue: .main)
        src.setEventHandler { [weak self] in self?.databaseChanged() }
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }

    private func databaseChanged() {
        // 이벤트가 연달아 오므로 0.3초 모아서 한 번 읽고, 파일이 교체됐을 수 있으니 파일 감시를 다시 건다.
        pendingPoll?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.poll()
            self?.watchAssertionsFile()
        }
        pendingPoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func poll() {
        let mode = Self.readActiveMode() ?? Self.fallbackMode()
        defer { applyPin() }
        guard initialized else {
            current = mode
            initialized = true
            return
        }
        guard mode != current else { return }
        let old = current
        current = mode
        guard settings.focusEnabled else { return }

        let excluded = AppSettings.list(settings.focusExcluded)
        if let mode {
            guard !excluded.contains(mode.name) else { return }
            post(mode, on: true)
        } else if let old {
            guard !excluded.contains(old.name) else { return }
            post(old, on: false)
        }
    }

    /// 미리보기: 지금 모드(없으면 방해금지 모드)로 켜짐/꺼짐 알림을 띄운다.
    func preview(on: Bool) {
        let mode = Self.readActiveMode() ?? Mode(id: "com.apple.donotdisturb.mode.default", name: T("방해금지 모드", "Do Not Disturb"),
                                                 symbol: "moon.fill", tint: .indigo)
        post(mode, on: on)
    }

    private func post(_ mode: Mode, on: Bool) {
        // 컴팩트: 아이콘 + 켬/끔, 상세: 모드 이름까지
        let short = on ? T("켬", "On") : T("끔", "Off")
        center.post(NotchActivity(
            kind: .focus,
            presentation: settings.focusStyle == .detail ? .detail : .compact,
            duration: AppSettings.duration(settings.focusDuration),
            symbol: mode.symbol,
            // 꺼짐: 같은 모드 아이콘만 반투명하게 해 비활성 느낌을 준다 (글자는 선명하게)
            tint: on ? mode.tint : mode.tint.opacity(0.35),
            value: .text(short),
            title: mode.name,
            subtitle: on ? T("집중 모드 켜짐", "Focus On") : T("집중 모드 꺼짐", "Focus Off"),
            wing: NetworkMonitor.wing(for: short)
        ))
    }

    /// '집중 모드 상시 표시': 켜져 있는 동안 노치 왼쪽에 작은 모드 아이콘을 남긴다.
    private func applyPin() {
        if settings.focusPinned, let mode = current, !AppSettings.list(settings.focusExcluded).contains(mode.name) {
            center.setPersistent(NotchActivity(
                kind: .focusPinned, priority: ActivityPriority.pinned,
                symbol: mode.symbol, tint: mode.tint, value: .none, title: mode.name, wing: 34
            ))
        } else {
            center.removePersistent(.focusPinned)
        }
    }

    // MARK: - ② 켜짐/꺼짐만 (INFocusStatusCenter)

    private static func fallbackMode() -> Mode? {
        let status = INFocusStatusCenter.default
        guard status.authorizationStatus == .authorized, status.focusStatus.isFocused == true else { return nil }
        return Mode(id: "unknown", name: T("집중 모드", "Focus"), symbol: "moon.fill", tint: .indigo)
    }

    // MARK: - ① DoNotDisturb DB (전체 디스크 접근 필요, 비공개 형식)

    static func readActiveMode() -> Mode? {
        guard let assertions = json(at: "Assertions.json"), let modeID = activeModeID(in: assertions) else { return nil }
        let config = json(at: "ModeConfigurations.json")
        let modeInfo = config.flatMap { findMode(id: modeID, in: $0) }
        let name = localizedName(modeInfo?["name"] as? String, id: modeID)
        let tint = color(named: modeInfo?["tintColorName"] as? String)
        return Mode(id: modeID, name: name, symbol: resolveSymbol(modeInfo?["symbolImageName"] as? String, id: modeID), tint: tint)
    }

    /// 지금 켜져 있는 모드. Assertions.json에는 켜진 기록(storeAssertionRecords)과
    /// 끝난 기록(storeInvalidationRecords)이 함께 있으므로 켜진 기록만 보고, 여러 개면 가장 최근 것을 쓴다.
    private static func activeModeID(in object: Any) -> String? {
        var records: [[String: Any]] = []
        collectRecords(in: object, into: &records)
        let active = records.compactMap { record -> (id: String, start: Double)? in
            guard let details = record["assertionDetails"] as? [String: Any],
                  let id = details["assertionDetailsModeIdentifier"] as? String else { return nil }
            return (id, (record["assertionStartDateTimestamp"] as? NSNumber)?.doubleValue ?? 0)
        }
        return active.max(by: { $0.start < $1.start })?.id
    }

    private static func collectRecords(in object: Any, into records: inout [[String: Any]]) {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if key == "storeAssertionRecords", let list = value as? [[String: Any]] {
                    records += list
                } else if !key.lowercased().contains("invalidation") {
                    collectRecords(in: value, into: &records)
                }
            }
        } else if let array = object as? [Any] {
            for value in array { collectRecords(in: value, into: &records) }
        }
    }

    /// 집중 모드 아이콘 중 일부(예: 업무의 person.lanyardcard.fill)는 시스템 전용이라 앱에서 그릴 수 없다.
    /// 비슷한 공개 심볼로 바꾸고, 그래도 없으면 모드 종류별 기본 아이콘 → 달 순으로 쓴다.
    private static let symbolAliases = [
        "person.lanyardcard.fill": "person.text.rectangle.fill",
        "person.lanyardcard": "person.text.rectangle",
    ]

    private static func resolveSymbol(_ symbol: String?, id: String) -> String {
        let candidates = [symbol, symbol.flatMap { symbolAliases[$0] }, defaultSymbol(for: id), "moon.fill"]
        for case let s? in candidates where NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil {
            return s
        }
        return "moon.fill"
    }

    /// 시스템 기본 모드는 DB에 영어 이름으로 저장되어 있어 한글로 바꿔 보여 준다.
    private static func localizedName(_ name: String?, id: String) -> String {
        switch id {
        case "com.apple.donotdisturb.mode.default": return T("방해금지 모드", "Do Not Disturb")
        case "com.apple.focus.reduce-interruptions": return T("방해 요소 줄이기", "Reduce Interruptions")
        default: break
        }
        if let name, !name.isEmpty {
            switch name {
            case "Do Not Disturb": return T("방해금지 모드", "Do Not Disturb")
            case "Sleep": return T("수면", "Sleep")
            case "Work": return T("업무", "Work")
            case "Personal": return T("개인 시간", "Personal")
            case "Driving": return T("운전", "Driving")
            case "Fitness": return T("피트니스", "Fitness")
            case "Gaming": return T("게임", "Gaming")
            case "Mindfulness": return T("마음챙김", "Mindfulness")
            case "Reading": return T("독서", "Reading")
            default: return name
            }
        }
        return defaultName(for: id)
    }

    private static func json(at name: String) -> Any? {
        guard let data = try? Data(contentsOf: dbURL.appendingPathComponent(name)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func findMode(id: String, in object: Any) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            if let mode = dict["mode"] as? [String: Any], mode["modeIdentifier"] as? String == id { return mode }
            for value in dict.values {
                if let m = findMode(id: id, in: value) { return m }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let m = findMode(id: id, in: value) { return m }
            }
        }
        return nil
    }

    private static func defaultName(for id: String) -> String {
        if id.hasSuffix(".default") { return T("방해금지 모드", "Do Not Disturb") }
        if id.contains("sleep") { return T("수면", "Sleep") }
        if id.contains("work") { return T("업무", "Work") }
        if id.contains("personal") { return T("개인 시간", "Personal") }
        if id.contains("driving") { return T("운전", "Driving") }
        return T("집중 모드", "Focus")
    }

    private static func defaultSymbol(for id: String) -> String {
        if id.contains("sleep") { return "bed.double.fill" }
        if id.contains("work") { return "person.text.rectangle.fill" }
        if id.contains("personal") { return "person.fill" }
        if id.contains("driving") { return "car.fill" }
        return "moon.fill"
    }

    private static func color(named name: String?) -> Color {
        switch name?.lowercased() ?? "" {
        case let n where n.contains("indigo"): return .indigo
        case let n where n.contains("purple"): return .purple
        case let n where n.contains("teal"): return .teal
        case let n where n.contains("cyan"): return .cyan
        case let n where n.contains("mint"): return .mint
        case let n where n.contains("green"): return .green
        case let n where n.contains("yellow"): return .yellow
        case let n where n.contains("orange"): return .orange
        case let n where n.contains("red"): return .red
        case let n where n.contains("pink"): return .pink
        case let n where n.contains("blue"): return .blue
        case let n where n.contains("brown"): return .brown
        case let n where n.contains("gray"): return .gray
        default: return .indigo
        }
    }
}
