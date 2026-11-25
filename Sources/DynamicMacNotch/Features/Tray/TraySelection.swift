import Foundation

/// 트레이 파일 선택. 화면과 저장소에 의존하지 않는 순수 계산이다 (`--tray-probe`로 확인).
struct TraySelection: Equatable {
    enum Direction { case left, right, up, down }

    private(set) var selected = Set<UUID>()
    /// 범위 선택의 시작점 (⇧ 클릭, ⇧ 화살표)
    private(set) var anchor: UUID?
    /// 키보드로 움직이는 현재 위치
    private(set) var cursor: UUID?

    /// 그냥 클릭 = 하나만, ⌘ = 추가/빼기, ⇧ = 시작점부터 범위
    mutating func click(_ id: UUID, order: [UUID], command: Bool, shift: Bool) {
        if shift, let anchor, let range = Self.range(anchor, id, in: order) {
            selected = range
        } else if command {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
        } else {
            selected = [id]
            anchor = id
        }
        cursor = id
    }

    /// 화살표: 그냥 = 옆 파일 하나만, ⇧ = 시작점부터 범위, ⌘ = 선택을 유지한 채 옆 파일 추가, ⇧⌘ = 그 방향 끝까지 범위
    mutating func move(_ direction: Direction, order: [UUID], columns: Int, shift: Bool, command: Bool) {
        guard !order.isEmpty else { return }
        guard let cursor, let index = order.firstIndex(of: cursor) else {
            // 아직 위치가 없으면 방향에 맞는 끝 파일에서 시작한다
            let first = direction == .left || direction == .up ? order[order.count - 1] : order[0]
            click(first, order: order, command: false, shift: false)
            return
        }
        let target = order[shift && command
            ? Self.edgeIndex(from: index, direction, count: order.count, columns: columns)
            : Self.nextIndex(from: index, direction, count: order.count, columns: columns)]
        if shift {
            let start = anchor ?? cursor
            selected = Self.range(start, target, in: order) ?? [target]
            anchor = start
        } else if command {
            selected.insert(target)
            anchor = target
        } else {
            selected = [target]
            anchor = target
        }
        self.cursor = target
    }

    /// 사각형 선택: `base`(⇧·⌘로 시작했을 때의 기존 선택)에 사각형 안의 파일을 더한다
    mutating func marquee(hit: [UUID], base: Set<UUID>) {
        selected = base.union(hit)
        if let first = hit.first {
            anchor = first
            cursor = hit.last
        }
    }

    mutating func selectAll(_ order: [UUID]) {
        selected = Set(order)
        anchor = order.first
        cursor = order.last
    }

    mutating func clear() {
        selected.removeAll()
        anchor = nil
        cursor = nil
    }

    /// 트레이에서 빠진 파일을 선택에서도 뺀다
    mutating func retain(_ order: [UUID]) {
        let alive = Set(order)
        selected.formIntersection(alive)
        if let anchor, !alive.contains(anchor) { self.anchor = nil }
        if let cursor, !alive.contains(cursor) { self.cursor = nil }
    }

    private static func range(_ a: UUID, _ b: UUID, in order: [UUID]) -> Set<UUID>? {
        guard let x = order.firstIndex(of: a), let y = order.firstIndex(of: b) else { return nil }
        return Set(order[min(x, y)...max(x, y)])
    }

    private static func nextIndex(from i: Int, _ direction: Direction, count: Int, columns: Int) -> Int {
        switch direction {
        case .left: return max(i - 1, 0)
        case .right: return min(i + 1, count - 1)
        case .up: return i >= columns ? i - columns : i
        // 마지막 줄이 짧으면 Finder처럼 마지막 파일로 간다
        case .down: return (i / columns) < (count - 1) / columns ? min(i + columns, count - 1) : i
        }
    }

    private static func edgeIndex(from i: Int, _ direction: Direction, count: Int, columns: Int) -> Int {
        switch direction {
        case .left: return i - i % columns
        case .right: return min(i - i % columns + columns - 1, count - 1)
        case .up: return 0
        case .down: return count - 1
        }
    }
}

#if DEV
/// 개발용: `--tray-probe` 선택 규칙을 확인한다.
enum TrayProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--tray-probe") else { return }
        let ids = (0..<8).map { _ in UUID() }   // 3열: 0 1 2 / 3 4 5 / 6 7
        var checks = 0, failures: [String] = []
        func check(_ s: TraySelection, _ want: [Int], _ cursor: Int?, _ what: String) {
            checks += 1
            let ok = s.selected == Set(want.map { ids[$0] }) && s.cursor == cursor.map { ids[$0] }
            if !ok { failures.append(what) }
        }
        func step(_ s: inout TraySelection, _ d: TraySelection.Direction, shift: Bool = false, command: Bool = false) {
            s.move(d, order: ids, columns: 3, shift: shift, command: command)
        }
        var s = TraySelection()
        step(&s, .right); check(s, [0], 0, "no cursor starts at the first file")
        s.clear(); step(&s, .up); check(s, [7], 7, "up with no cursor starts at the last file")
        s.clear(); s.click(ids[4], order: ids, command: false, shift: false); check(s, [4], 4, "click")
        step(&s, .right); check(s, [5], 5, "right")
        step(&s, .right); check(s, [6], 6, "right wraps to the next row")
        step(&s, .up); check(s, [3], 3, "up")
        step(&s, .up); check(s, [0], 0, "up")
        step(&s, .up); check(s, [0], 0, "up stops at the first row")
        step(&s, .left); check(s, [0], 0, "left stops at the first file")
        s.click(ids[5], order: ids, command: false, shift: false)
        step(&s, .down); check(s, [7], 7, "down goes to the last file on a short row")
        step(&s, .down); check(s, [7], 7, "down stops at the last row")
        s.click(ids[1], order: ids, command: false, shift: false)
        step(&s, .right, shift: true); check(s, [1, 2], 2, "shift right extends")
        step(&s, .down, shift: true); check(s, [1, 2, 3, 4, 5], 5, "shift down extends by a row")
        step(&s, .up, shift: true); step(&s, .left, shift: true); check(s, [1], 1, "shrinks back to the anchor")
        step(&s, .left, shift: true); check(s, [0, 1], 0, "shift crosses the anchor")
        s.click(ids[1], order: ids, command: false, shift: false)
        step(&s, .right, command: true); check(s, [1, 2], 2, "command adds the next file")
        step(&s, .down, command: true); check(s, [1, 2, 5], 5, "command keeps a gap")
        s.click(ids[4], order: ids, command: false, shift: false)
        step(&s, .right, shift: true, command: true); check(s, [4, 5], 5, "shift command to the row end")
        step(&s, .left, shift: true, command: true); check(s, [3, 4], 3, "shift command to the row start")
        step(&s, .down, shift: true, command: true); check(s, [4, 5, 6, 7], 7, "shift command to the last file")
        step(&s, .up, shift: true, command: true); check(s, [0, 1, 2, 3, 4], 0, "shift command to the first file")
        s.click(ids[0], order: ids, command: false, shift: false); s.click(ids[2], order: ids, command: true, shift: false)
        check(s, [0, 2], 2, "command click adds")
        s.click(ids[2], order: ids, command: true, shift: false); check(s, [0], 2, "command click removes")
        s.click(ids[1], order: ids, command: false, shift: false); s.click(ids[4], order: ids, command: false, shift: true)
        check(s, [1, 2, 3, 4], 4, "shift click range")
        s.marquee(hit: [ids[6], ids[7]], base: []); check(s, [6, 7], 7, "marquee")
        s.marquee(hit: [ids[0]], base: [ids[6], ids[7]]); check(s, [0, 6, 7], 0, "marquee adds to the base")
        s.marquee(hit: [], base: []); check(s, [], 0, "empty marquee clears")
        s.selectAll(ids); check(s, Array(0..<8), 7, "select all")
        s.retain(Array(ids[0..<3])); check(s, [0, 1, 2], nil, "removed files leave the selection")
        s.clear(); s.move(.right, order: [], columns: 3, shift: false, command: false); check(s, [], nil, "empty tray")
        checkCopies { ok, what in
            checks += 1
            if !ok { failures.append(what) }
        }
        print("tray checks=\(checks) failures=\(failures.count)")
        failures.forEach { print("  FAIL", $0) }
        exit(failures.isEmpty ? 0 : 1)
    }

    /// 트레이 복사본: 임시 폴더·시험용 저장소만 쓰고 실제 트레이와 휴지통은 건드리지 않는다
    private static func checkCopies(_ check: (Bool, String) -> Void) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dmn-tray-probe-" + UUID().uuidString, isDirectory: true)
        let copies = root.appendingPathComponent("Tray", isDirectory: true), desk = root.appendingPathComponent("Desk", isDirectory: true)
        try? fm.createDirectory(at: desk, withIntermediateDirectories: true)
        let suite = "dmn-tray-probe", defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: root)
        }
        var trashed: [String] = [], trashWorks = true
        func store() -> TrayStore {
            TrayStore(center: ActivityCenter(), defaults: defaults, copyFolder: copies) { url in
                guard trashWorks else { return false }
                trashed.append(url.lastPathComponent)
                return (try? fm.removeItem(at: url)) != nil   // 시험에서는 휴지통 대신 지운다 (임시 파일)
            }
        }
        func folders() -> Int { ((try? fm.contentsOfDirectory(atPath: copies.path)) ?? []).count }
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        let tray = store()
        check(tray.addData(png, name: "a.png") && tray.items.count == 1, "clipboard capture is added")
        let a = tray.items[0]
        check(a.isCopy && a.isOnlyCopy == true && (try? Data(contentsOf: a.url)) == png, "kept as a file by the tray")
        check(a.path.hasPrefix(copies.path), "kept in the tray folder, not a temporary folder")
        check(store().items.first?.isOnlyCopy == true, "still there after relaunch")
        tray.remove(a)
        check(trashed == ["a.png"] && folders() == 0 && tray.items.isEmpty, "leaving the tray sends it to the Trash")

        _ = tray.addData(png, name: "b.png")
        trashWorks = false
        tray.clear()
        check(folders() == 1, "kept when it can't go to the Trash")
        trashWorks = true
        for f in (try? fm.contentsOfDirectory(at: copies, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }

        // 사용자가 복사본을 다른 폴더로 옮긴 뒤 트레이에서 빼도, 옮긴 폴더는 그대로여야 한다
        _ = tray.addData(png, name: "c.png")
        let moved = desk.appendingPathComponent("c.png"), other = desk.appendingPathComponent("other.txt")
        try? Data("keep".utf8).write(to: other)
        try? fm.moveItem(atPath: tray.items[0].path, toPath: moved.path)
        tray.clear()
        check(fm.fileExists(atPath: other.path) && fm.fileExists(atPath: moved.path), "a copy moved elsewhere leaves that folder alone")
        check(folders() == 0, "its empty tray folder is cleaned up")

        // 끌어낸 뒤에는 받는 앱이 읽을 수 있게 남아 있고, 다음 실행 때 치운다
        _ = tray.addData(png, name: "d.png")
        let d = tray.items[0]
        tray.delivered(ids: [d.id])
        check(tray.items.isEmpty && fm.fileExists(atPath: d.path), "a dragged-out copy stays readable")
        _ = store()
        check(!fm.fileExists(atPath: d.path) && trashed.last == "d.png" && folders() == 0, "and is cleaned up on the next launch")

        // 저장 파일로 된 스크린샷은 그 파일을 참조만 한다
        let file = desk.appendingPathComponent("e.png")
        try? png.write(to: file)
        tray.add([file])
        let e = tray.items.first
        if e?.isCopy == false {
            tray.clear()
            check(fm.fileExists(atPath: file.path), "a referenced file is never removed")
        } else {
            tray.clear()
            check(fm.fileExists(atPath: file.path), "the original stays when copies are kept")
        }
        // 복사본 폴더 밖을 가리키는 저장값은 치우지 않는다
        let stray = [["path": other.path, "trash": false] as [String: Any]]
        defaults.set(try? JSONSerialization.data(withJSONObject: stray), forKey: "trayDelivered")
        _ = store()
        check(fm.fileExists(atPath: other.path), "never cleans outside the tray folder")
        // 예전 버전이 저장한 항목(isOnlyCopy 없음)도 읽는다
        let old = [["id": UUID().uuidString, "bookmark": Data().base64EncodedString(), "path": file.path, "added": Date().timeIntervalSinceReferenceDate, "isCopy": false] as [String: Any]]
        defaults.set(try? JSONSerialization.data(withJSONObject: old), forKey: "trayItems")
        check(store().items.count == 1, "items saved by older versions load")
    }
}
#endif
