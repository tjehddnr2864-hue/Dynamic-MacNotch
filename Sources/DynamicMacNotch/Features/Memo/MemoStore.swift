import Foundation

/// 메모 한 개 (파일 하나)
struct Memo: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var body: String
    var updated: Date

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 목록에 보일 요약 (본문 전체는 읽어 두지 않는다)
struct MemoSummary: Identifiable, Equatable {
    var id: UUID
    var title: String
    var preview: String
    var updated: Date
}

/// 메모 저장소.
/// 메모는 메모 페이지가 보이는 동안에만 메모리에 올린다. 페이지가 닫히면(노치 축소·다른 페이지) 바로 저장하고
/// 몇 초 뒤 메모리에서 내린다. 다시 열면 디스크에서 읽어 마지막으로 쓰던 메모를 이어서 연다.
/// 쓰는 동안에는 잠깐 멈출 때마다 자동 저장하므로, 저장하지 않고 나가도 내용이 남는다.
final class MemoStore: ObservableObject {
    /// 지금 열려 있는 메모 (페이지가 보일 때만)
    @Published private(set) var current: Memo?
    /// 메모 목록 (목록을 펼쳤을 때만)
    @Published private(set) var summaries: [MemoSummary]?
    @Published var showList = false

    private var saveWork: DispatchWorkItem?
    private var unloadWork: DispatchWorkItem?
    private var dirty = false
    private static let currentKey = "memoCurrentID"
    /// 페이지가 닫힌 뒤 메모리에서 내리기까지
    private static let unloadDelay: TimeInterval = 5

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DynamicMacNotch/Memos", isDirectory: true)
    }

    private static func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    // MARK: - 페이지 열림·닫힘

    func pageAppeared() {
        unloadWork?.cancel()
        unloadWork = nil
        guard current == nil else { return }
        let saved = UserDefaults.standard.string(forKey: Self.currentKey).flatMap(UUID.init)
        current = saved.flatMap(Self.read) ?? Self.newMemo()
        if showList { reloadList() }
    }

    func pageDisappeared() {
        saveNow()
        unloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.saveNow()
            self.current = nil
            self.summaries = nil
            self.unloadWork = nil
        }
        unloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unloadDelay, execute: work)
    }

    // MARK: - 편집

    func setTitle(_ title: String) {
        guard var m = current, m.title != title else { return }
        m.title = title
        edited(m)
    }

    func setBody(_ body: String) {
        guard var m = current, m.body != body else { return }
        m.body = body
        edited(m)
    }

    private func edited(_ m: Memo) {
        var m = m
        m.updated = Date()
        current = m
        dirty = true
        // 입력이 0.8초 멈추면 저장
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard dirty, let m = current else { return }
        dirty = false
        UserDefaults.standard.set(m.id.uuidString, forKey: Self.currentKey)
        // 빈 메모는 남기지 않는다
        if m.isEmpty {
            try? FileManager.default.removeItem(at: Self.file(m.id))
        } else {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(m) { try? data.write(to: Self.file(m.id), options: .atomic) }
        }
        if showList { reloadList() }
    }

    // MARK: - 새 메모·불러오기·삭제

    func createNew() {
        saveNow()
        let m = Self.newMemo()
        current = m
        UserDefaults.standard.set(m.id.uuidString, forKey: Self.currentKey)
    }

    func open(_ id: UUID) {
        guard id != current?.id else { return }
        saveNow()
        guard let m = Self.read(id) else { reloadList(); return }
        current = m
        UserDefaults.standard.set(id.uuidString, forKey: Self.currentKey)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.file(id))
        if current?.id == id {
            dirty = false
            // 남은 메모 중 가장 최근 것, 없으면 새 메모
            let next = Self.loadSummaries().first.flatMap { Self.read($0.id) } ?? Self.newMemo()
            current = next
            UserDefaults.standard.set(next.id.uuidString, forKey: Self.currentKey)
        }
        reloadList()
    }

    func toggleList() {
        showList.toggle()
        if showList { reloadList() } else { summaries = nil }
    }

    private func reloadList() {
        summaries = Self.loadSummaries()
    }

    // MARK: - 파일

    private static func newMemo() -> Memo {
        Memo(id: UUID(), title: "", body: "", updated: Date())
    }

    private static func read(_ id: UUID) -> Memo? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode(Memo.self, from: data)
    }

    private static func loadSummaries() -> [MemoSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url -> MemoSummary? in
                guard let data = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(Memo.self, from: data) else { return nil }
                let firstLine = m.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                return MemoSummary(id: m.id, title: m.title, preview: String(firstLine.prefix(60)), updated: m.updated)
            }
            .sorted { $0.updated > $1.updated }
    }
}
