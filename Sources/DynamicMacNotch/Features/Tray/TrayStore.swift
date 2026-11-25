import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// 파일 트레이와 에어드랍 (가이드라인 5.2).
/// 파일은 원본을 옮기지 않고 북마크로 참조한다(옵션: 복사본 보관). 재시작 후에도 유지된다.
final class TrayStore: NSObject, ObservableObject, NSSharingServiceDelegate {
    struct Item: Identifiable, Codable, Equatable {
        var id = UUID()
        var bookmark: Data
        var path: String
        var added = Date()
        var isCopy = false
        /// 원본이 따로 없는 파일 (트레이로 보낸 클립보드 스크린샷). 없앨 때 지우지 않고 휴지통으로 보낸다.
        /// 예전에 저장된 항목에는 없으므로 옵셔널
        var isOnlyCopy: Bool?

        var url: URL {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return u
            }
            return URL(fileURLWithPath: path)
        }
    }

    enum DropZone { case airdrop, tray }

    @Published private(set) var items: [Item] = []
    /// 드래그 중 커서가 올라가 있는 영역
    @Published var targeted: DropZone?
    /// 마지막으로 파일을 놓은 시각 (놓는 순간의 클릭이 파일 선택 창을 여는 것을 막음)
    var lastDrop = Date.distantPast
    /// 트레이에서 선택된 파일과 키보드 위치
    @Published private(set) var picked = TraySelection()
    var selection: Set<UUID> { picked.selected }
    private var order: [UUID] { items.map(\.id) }
    /// 페이지가 열린 동안 파일 경로를 기억한다 (사각형 선택 중 화면을 다시 그릴 때마다 북마크를 풀지 않게)
    private var urlCache: [UUID: URL] = [:]
    private var cleanupWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    /// 트레이 파일을 끌고 있는지 (끄는 동안에는 자동 정리를 미룬다)
    var isDraggingItems = false
    /// 파일이나 빈 곳을 누르면 트레이가 키 입력을 받게 한다 (TrayKeyCatcher가 연결)
    var requestKeyFocus: (() -> Void)?

    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private let storeKey = "trayItems"
    private let deliveredKey = "trayDelivered"
    private var airdropSubscriber: Any?
    private var airdropFiles: [URL] = []

    static let copyFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Dynamic MacNotch/Tray", isDirectory: true)
    }()

    private let defaults: UserDefaults
    private let copyFolder: URL
    private let trash: (URL) -> Bool

    /// 저장소·복사본 폴더·휴지통은 시험(`--tray-probe`)에서만 바꿔 넣는다
    init(center: ActivityCenter, defaults: UserDefaults = .standard, copyFolder: URL = TrayStore.copyFolder,
         trash: @escaping (URL) -> Bool = { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) != nil }) {
        self.center = center
        self.defaults = defaults
        self.copyFolder = copyFolder
        self.trash = trash
        super.init()
        load()
        disposeDelivered()   // 지난 실행에서 끌어내고 남은 복사본
        cleanup()
        settings.$trayCleanupMinutes
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cleanup() }
            .store(in: &cancellables)
    }

    // MARK: - 트레이

    /// 원본이 없는 이미지(클립보드 스크린샷)를 트레이가 파일로 보관한다.
    /// 임시 폴더에 두면 macOS가 치워서 사라지므로 트레이의 복사본 폴더에 쓴다.
    func addData(_ data: Data, name: String) -> Bool {
        let folder = copyFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dest = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
            let bookmark = try dest.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            items.append(Item(bookmark: bookmark, path: dest.path, isCopy: true, isOnlyCopy: true))
        } catch {
            try? FileManager.default.removeItem(at: folder)   // 방금 만든 폴더
            return false
        }
        itemsChanged()
        return true
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.path == url.path }) {
            var target = url
            var isCopy = false
            if settings.trayKeepCopies {
                let folder = copyFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let dest = folder.appendingPathComponent(url.lastPathComponent)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    target = dest
                    isCopy = true
                }
            }
            guard let bookmark = try? target.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
            items.append(Item(bookmark: bookmark, path: target.path, isCopy: isCopy))
        }
        itemsChanged()
    }

    /// 표시용 파일 경로
    func url(for item: Item) -> URL {
        if let cached = urlCache[item.id] { return cached }
        let url = item.url
        urlCache[item.id] = url
        return url
    }

    /// 노치가 닫히면 화면용 기억을 비운다
    func releaseViewCaches() { urlCache.removeAll() }

    func select(_ item: Item, command: Bool, shift: Bool) {
        picked.click(item.id, order: order, command: command, shift: shift)
    }

    func moveSelection(_ direction: TraySelection.Direction, columns: Int, shift: Bool, command: Bool) {
        picked.move(direction, order: order, columns: columns, shift: shift, command: command)
    }

    func selectByMarquee(hit: [UUID], base: Set<UUID>) {
        var next = picked
        next.marquee(hit: hit, base: base)
        if next != picked { picked = next }
    }

    func selectAll() { picked.selectAll(order) }

    func clearSelection() { picked.clear() }

    func remove(ids: Set<UUID>) {
        discard(items.filter { ids.contains($0.id) })
    }

    /// 다른 앱으로 끌어낸 파일(들)을 트레이에서 뺀다. 받는 앱이 나중에 읽을 수 있어 복사본은 잠시 뒤에 치운다.
    func delivered(ids: Set<UUID>) {
        discard(items.filter { ids.contains($0.id) }, delivered: true)
    }

    func remove(_ item: Item) { discard([item]) }

    func clear() { discard(items) }

    /// 목록에서 뺀다. 원본 파일은 건드리지 않고, 트레이가 만든 복사본만 치운다.
    private func discard(_ gone: [Item], delivered: Bool = false) {
        guard !gone.isEmpty else { return }
        let ids = Set(gone.map(\.id))
        items.removeAll { ids.contains($0.id) }
        itemsChanged()
        let copies = gone.filter(\.isCopy).map { Copy(path: $0.path, trash: $0.isOnlyCopy == true) }
        guard !copies.isEmpty else { return }
        if delivered {
            deliveredCopies += copies
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + Self.deliveredKeep) { [weak self] in
                self?.disposeDelivered(copies)
            }
        } else {
            copies.forEach(dispose)
        }
    }

    /// 트레이가 만든 복사본 (넣을 때의 경로)
    private struct Copy: Codable, Equatable {
        var path: String
        var trash: Bool
    }

    /// 끌어낸 복사본을 남겨 두는 시간(초)
    private static let deliveredKeep: TimeInterval = 600

    /// 끌어냈고 아직 치우지 않은 복사본. 앱이 먼저 끝나면 다음 실행 때 치운다.
    private var deliveredCopies: [Copy] {
        get { defaults.data(forKey: deliveredKey).flatMap { try? JSONDecoder().decode([Copy].self, from: $0) } ?? [] }
        set {
            if newValue.isEmpty { defaults.removeObject(forKey: deliveredKey) } else { defaults.set(try? JSONEncoder().encode(newValue), forKey: deliveredKey) }
        }
    }

    private func disposeDelivered(_ copies: [Copy]? = nil) {
        let all = deliveredCopies, due = copies ?? all
        guard !due.isEmpty else { return }
        deliveredCopies = all.filter { !due.contains($0) }
        due.forEach(dispose)
    }

    /// 복사본을 치운다. 반드시 넣을 때 만든 폴더(복사본 폴더/UUID) 안에서만 한다:
    /// 북마크는 사용자가 옮긴 파일을 따라가므로, 그 위치를 기준으로 지우면 옮긴 곳의 폴더(데스크탑 등)를 통째로 지울 수 있다.
    private func dispose(_ copy: Copy) {
        let file = URL(fileURLWithPath: copy.path).standardizedFileURL
        let folder = file.deletingLastPathComponent()
        guard UUID(uuidString: folder.lastPathComponent) != nil,
              folder.deletingLastPathComponent().path == copyFolder.standardizedFileURL.path else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path), copy.trash, !trash(file) { return }   // 휴지통으로 못 보내면 남겨 둔다
        try? fm.removeItem(at: folder)
    }

    private func itemsChanged() {
        picked.retain(order)
        urlCache = urlCache.filter { id, _ in items.contains { $0.id == id } }
        save()
        scheduleCleanup()
    }

    // MARK: - 자동 정리

    /// 설정한 시간보다 오래된 항목과 원본이 사라진 항목을 뺀다
    func cleanup() {
        let minutes = settings.trayCleanupMinutes
        if isDraggingItems {
            scheduleCleanup(after: 30)
            return
        }
        let limit = Date().addingTimeInterval(-minutes * 60)
        discard(items.filter { item in
            (minutes > 0 && item.added <= limit) || !FileManager.default.fileExists(atPath: item.url.path)
        })
        scheduleCleanup()
    }

    /// 가장 먼저 만료되는 항목에 맞춰 한 번만 깨어난다 (주기적으로 확인하지 않음). 잠자기 시간도 함께 센다.
    private func scheduleCleanup(after delay: TimeInterval? = nil) {
        cleanupWork?.cancel()
        cleanupWork = nil
        let minutes = settings.trayCleanupMinutes
        guard minutes > 0, let oldest = items.map(\.added).min() else { return }
        let seconds = delay ?? max(1, oldest.addingTimeInterval(minutes * 60).timeIntervalSinceNow)
        let work = DispatchWorkItem { [weak self] in self?.cleanup() }
        cleanupWork = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + seconds, execute: work)
    }

    private func load() {
        guard let data = defaults.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: storeKey) }
    }

    // MARK: - 드롭 처리

    static func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    // MARK: - 에어드랍

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.delegate = self
        airdropFiles = urls
        NSApp.activate(ignoringOtherApps: true)   // 에어드랍 창이 앞으로 나오도록
        guard service.canPerform(withItems: urls) else {
            postAirDropResult(success: false, message: T("에어드랍을 사용할 수 없습니다", "AirDrop is unavailable"))
            return
        }
        service.perform(withItems: urls)
    }

    /// 실제로 전송이 진행됐는지 (진행률을 한 번이라도 받았는지). 취소하면 false로 남는다.
    private var airdropTransferred = false

    func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any]) {
        airdropTransferred = false
        // 전송 진행률: 공개 API가 없어 파일에 게시되는 NSProgress를 시도하고, 없으면 회전 링.
        let first = airdropFiles.first
        center.setPersistent(airdropActivity(fraction: nil))
        if let first {
            airdropSubscriber = Progress.addSubscriber(forFileURL: first) { [weak self] progress in
                let obs = progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if p.fractionCompleted > 0 { self.airdropTransferred = true }
                        self.center.setPersistent(self.airdropActivity(fraction: p.fractionCompleted))
                    }
                }
                return { obs.invalidate() }
            }
        }
    }

    /// 에어드랍 창에서 '취소'를 눌러도 이 콜백이 불리므로, 실제 전송 진행이 있었을 때만 완료를 알린다.
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let transferred = airdropTransferred
        endAirDrop()
        if transferred { postAirDropResult(success: true, message: T("전송 완료", "Sent")) }
    }

    /// 에어드랍으로 파일을 받았을 때 (DownloadMonitor가 알림)
    func airDropReceived(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let names = urls.count > 1 ? T("\(first.lastPathComponent) 외 \(urls.count - 1)개", "\(first.lastPathComponent) and \(urls.count - 1) more") : first.lastPathComponent
        center.post(NotchActivity(
            kind: .airdrop, presentation: .detail, duration: 5,
            symbol: "airplayaudio", tint: .blue, value: .check,
            title: T("에어드랍 받음", "AirDrop Received"), subtitle: names,
            artwork: TrayItemView.icon(for: first), fileURL: first
        ))
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        airdropTransferred = false
        endAirDrop()
        // 사용자가 취소한 경우는 조용히 끝낸다.
        if (error as NSError).code == NSUserCancelledError { return }
        postAirDropResult(success: false, message: T("전송 실패", "Failed"))
    }

    private func endAirDrop() {
        if let s = airdropSubscriber { Progress.removeSubscriber(s) }
        airdropSubscriber = nil
        center.removePersistent(.airdrop)
    }

    private func airdropActivity(fraction: Double?) -> NotchActivity {
        let value: ActivityValue = fraction.map { settings.airdropStyle == .percent ? .percent($0) : .ring($0) } ?? .spinner
        return NotchActivity(kind: .airdrop, priority: ActivityPriority.download + 1,
                             symbol: "airplayaudio", tint: .blue, value: value,
                             title: T("에어드랍", "AirDrop"), subtitle: airdropFiles.first?.lastPathComponent, wing: 50)
    }

    private func postAirDropResult(success: Bool, message: String) {
        center.post(NotchActivity(kind: .airdrop, symbol: success ? "checkmark.circle.fill" : "xmark.circle.fill",
                                  tint: success ? .green : .red, value: .text(message), title: T("에어드랍", "AirDrop"),
                                  wing: NetworkMonitor.wing(for: message)))
    }
}
