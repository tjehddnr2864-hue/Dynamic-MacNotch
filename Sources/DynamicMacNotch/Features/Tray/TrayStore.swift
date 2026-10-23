import AppKit
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
    /// 트레이에서 선택된 파일 (⌘ 클릭 여러 개, ⇧ 클릭 범위)
    @Published var selection = Set<UUID>()
    private var selectionAnchor: UUID?

    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private let storeKey = "trayItems"
    private var airdropSubscriber: Any?
    private var airdropFiles: [URL] = []

    private static let copyFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Dynamic MacNotch/Tray", isDirectory: true)
    }()

    init(center: ActivityCenter) {
        self.center = center
        super.init()
        load()
        cleanup()
    }

    // MARK: - 트레이

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.path == url.path }) {
            var target = url
            var isCopy = false
            if settings.trayKeepCopies {
                let folder = Self.copyFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
        save()
    }

    /// 클릭으로 선택: 그냥 클릭 = 하나만, ⌘ = 추가/빼기, ⇧ = 마지막 선택부터 범위
    func select(_ item: Item, command: Bool, shift: Bool) {
        if shift, let anchor = selectionAnchor,
           let a = items.firstIndex(where: { $0.id == anchor }), let b = items.firstIndex(where: { $0.id == item.id }) {
            selection = Set(items[min(a, b)...max(a, b)].map(\.id))
        } else if command {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            selectionAnchor = item.id
        } else {
            selection = [item.id]
            selectionAnchor = item.id
        }
    }

    func clearSelection() { selection.removeAll() }

    /// 끌어낸 파일(들)을 트레이에서 뺀다
    func remove(ids: Set<UUID>) {
        for item in items where ids.contains(item.id) && item.isCopy {
            try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
        }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        save()
    }

    func remove(_ item: Item) {
        if item.isCopy { try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent()) }
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        for item in items where item.isCopy { try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent()) }
        items.removeAll()
        save()
    }

    /// 자동 정리: 설정한 일수보다 오래된 항목, 원본이 사라진 항목 제거.
    func cleanup() {
        let days = settings.trayCleanupDays
        items.removeAll { item in
            let expired = days > 0 && item.added < Date().addingTimeInterval(-days * 86400)
            return expired || !FileManager.default.fileExists(atPath: item.url.path)
        }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: storeKey) }
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

// MARK: - 트레이 페이지 (좁은 확장 영역)

struct TrayPage: View {
    @ObservedObject var store: TrayStore
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        if vm.isFileDragging || store.items.isEmpty {
            dropZones
        } else {
            itemList
        }
    }

    /// 드래그 중: [에어드랍] [트레이] 두 영역
    private var dropZones: some View {
        HStack(spacing: 6) {
            zone(.airdrop, symbol: "airplayaudio", title: T("에어드랍", "AirDrop"))
            zone(.tray, symbol: "tray.and.arrow.down.fill", title: T("트레이", "Tray"))
        }
    }

    /// 칸 하나: 파일을 끌고 있을 때는 놓는 곳으로만 동작하고(클릭 무시),
    /// 끌고 있지 않을 때는 클릭하면 파일 선택 창이 열린다. 두 동작이 서로 겹치지 않는다.
    private func zone(_ z: TrayStore.DropZone, symbol: String, title: String) -> some View {
        let on = store.targeted == z
        let hovered = !vm.isFileDragging && hoveredZone == z
        return zoneLabel(z, symbol: symbol, title: title, on: on || hovered)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(zoneBackground(on: on, hovered: hovered))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(on ? 1.04 : (hovered ? 1.02 : 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
            .onHover { inside in
                if inside { hoveredZone = z } else if hoveredZone == z { hoveredZone = nil }
            }
            .onTapGesture { pick(for: z) }
            .onDrop(of: [.fileURL], isTargeted: targetBinding(z)) { providers in
                handleDrop(providers, zone: z)
            }
            .help(vm.isFileDragging ? "" : (z == .airdrop ? T("클릭해서 에어드랍으로 보낼 파일 고르기", "Click to choose files to AirDrop") : T("클릭해서 트레이에 추가할 파일 고르기", "Click to choose files for the tray")))
    }

    private let hoverState = State(initialValue: TrayStore.DropZone?.none)
    private var hoveredZone: TrayStore.DropZone? {
        get { hoverState.wrappedValue }
        nonmutating set { hoverState.wrappedValue = newValue }
    }

    /// 클릭으로 파일 고르기. 파일을 끄는 중이거나 방금 놓은 직후(놓을 때의 마우스 떼기)는 무시한다.
    private func pick(for z: TrayStore.DropZone) {
        guard !vm.isFileDragging, store.targeted == nil, Date().timeIntervalSince(store.lastDrop) > 0.6 else { return }
        FilePicker.choose(z == .airdrop ? .airdrop : .tray) { urls in
            if z == .airdrop { store.airDrop(urls) } else { store.add(urls) }
        }
    }

    private func zoneLabel(_ z: TrayStore.DropZone, symbol: String, title: String, on: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
            Text(title).font(.system(size: 11, weight: .semibold))
            if !vm.isFileDragging {
                Text(T("클릭 또는 끌어다 놓기", "Click or drop files")).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .foregroundStyle(on ? Color.white : Color.white.opacity(0.7))
    }

    private func zoneBackground(on: Bool, hovered: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let stroke = StrokeStyle(lineWidth: 1.5, dash: on ? [] : [4, 3])
        return ZStack {
            shape.fill(on ? Color.blue.opacity(0.25) : Color.white.opacity(hovered ? 0.08 : 0))
            shape.strokeBorder(on ? Color.blue : Color.white.opacity(hovered ? 0.45 : 0.25), style: stroke)
        }
    }

    private func targetBinding(_ z: TrayStore.DropZone) -> Binding<Bool> {
        Binding(
            get: { store.targeted == z },
            set: { isOn in
                if isOn { store.targeted = z } else if store.targeted == z { store.targeted = nil }
            }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider], zone z: TrayStore.DropZone) -> Bool {
        store.lastDrop = Date()
        TrayStore.loadURLs(providers) { urls in
            if z == .airdrop { store.airDrop(urls) } else { store.add(urls) }
            vm.endFileDrag(dropped: true)
        }
        Haptics.perform()
        return true
    }

    /// 보관 중인 파일 목록. 각 파일을 끌어내 다른 앱에 첨부할 수 있다.
    private var itemList: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(T("트레이 \(store.items.count)", "Tray \(store.items.count)"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button {
                    FilePicker.choose(.tray) { store.add($0) }
                } label: { Image(systemName: "plus") }
                    .help(T("파일 골라서 추가", "Add files"))
                Button {
                    let chosen = store.items.filter { store.selection.contains($0.id) }
                    store.airDrop((chosen.isEmpty ? store.items : chosen).map(\.url))
                } label: { Image(systemName: "airplayaudio") }
                    .help(store.selection.isEmpty ? T("모두 에어드랍", "AirDrop all") : T("선택한 파일 에어드랍", "AirDrop selected"))
                Button { store.clear() } label: { Image(systemName: "trash") }
                    .help(T("모두 비우기", "Clear all"))
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.8))

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(46), spacing: 6), count: 3), spacing: 6) {
                    ForEach(store.items) { item in
                        TrayItemView(item: item, store: store)
                    }
                }
            }
            .background(Color.black.opacity(0.001).onTapGesture { store.clearSelection() })
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            store.lastDrop = Date()
            TrayStore.loadURLs(providers) { store.add($0) }
            return true
        }
    }
}

struct TrayItemView: View {
    /// 다시 그릴 때마다 아이콘을 새로 만들지 않도록 경로별로 재사용한다.
    private static var iconCache: [String: NSImage] = [:]

    static func clearIconCache() { iconCache.removeAll() }

    static func icon(for url: URL) -> NSImage {
        if let cached = iconCache[url.path] { return cached }
        if iconCache.count > 100 { iconCache.removeAll() }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[url.path] = icon
        return icon
    }

    var item: TrayStore.Item
    @ObservedObject var store: TrayStore

    var body: some View {
        let url = item.url
        let selected = store.selection.contains(item.id)
        VStack(spacing: 2) {
            Image(nsImage: TrayItemView.icon(for: url))
                .resizable()
                .frame(width: 30, height: 30)
            Text(url.lastPathComponent)
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 46, height: 46)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.accentColor.opacity(selected ? 0.45 : 0)))
        // 클릭·⌘클릭·⇧클릭 선택, 더블클릭 열기, 우클릭 메뉴, 여러 파일 끌기는 AppKit이 처리
        .overlay(TrayItemInteraction(item: item, store: store))
        .help(url.lastPathComponent)
    }
}

/// 트레이 파일 하나의 마우스 처리 (SwiftUI의 onDrag는 파일 하나만 끌 수 있어 AppKit 드래그 세션을 쓴다)
struct TrayItemInteraction: NSViewRepresentable {
    var item: TrayStore.Item
    var store: TrayStore

    func makeNSView(context: Context) -> TrayItemNSView { TrayItemNSView() }

    func updateNSView(_ v: TrayItemNSView, context: Context) {
        v.item = item
        v.store = store
    }
}

final class TrayItemNSView: NSView, NSDraggingSource {
    var item: TrayStore.Item?
    weak var store: TrayStore?
    private var downEvent: NSEvent?
    private var draggedIDs = Set<UUID>()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let item, let store else { return }
        if event.clickCount == 2 {
            NSWorkspace.shared.open(item.url)
            return
        }
        let mods = event.modifierFlags
        // 이미 선택된 파일을 그냥 누르면 선택을 유지한다 (여러 개를 함께 끌 수 있도록)
        if !(mods.contains(.command) || mods.contains(.shift)) && store.selection.contains(item.id) {
            downEvent = event
            return
        }
        store.select(item, command: mods.contains(.command), shift: mods.contains(.shift))
        downEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        // 선택된 여러 개 중 하나를 끌지 않고 그냥 놓으면 그 하나만 선택
        if let item, let store, let down = downEvent, event.clickCount < 2,
           !down.modifierFlags.contains(.command), !down.modifierFlags.contains(.shift), store.selection.count > 1 {
            store.select(item, command: false, shift: false)
        }
        downEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, let item, let store else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) > 3 else { return }
        downEvent = nil
        if !store.selection.contains(item.id) { store.select(item, command: false, shift: false) }
        let dragged = store.items.filter { store.selection.contains($0.id) }
        draggedIDs = Set(dragged.map(\.id))
        let dragItems: [NSDraggingItem] = dragged.enumerated().map { i, it in
            let d = NSDraggingItem(pasteboardWriter: it.url as NSURL)
            let offset = CGFloat(min(i, 4)) * 4
            d.setDraggingFrame(CGRect(x: 8 + offset, y: 12 - offset, width: 30, height: 30),
                               contents: TrayItemView.icon(for: it.url))
            return d
        }
        guard !dragItems.isEmpty else { return }
        let session = beginDraggingSession(with: dragItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 원본 파일을 참조하므로 다른 곳에는 복사로 넘긴다
        context == .outsideApplication ? [.copy, .generic] : []
    }

    /// 다른 앱(Finder·메일 등)에 놓는 데 성공하면 트레이에서 뺀다
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [], let store { store.remove(ids: draggedIDs) }
        draggedIDs.removeAll()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let item, let store else { return }
        if !store.selection.contains(item.id) { store.select(item, command: false, shift: false) }
        let selected = store.items.filter { store.selection.contains($0.id) }
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let mi = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let target = MenuAction(action)
            mi.target = target
            mi.representedObject = target   // 메뉴가 떠 있는 동안 대상 유지
            menu.addItem(mi)
        }
        let urls = selected.map(\.url)
        add(urls.count > 1 ? T("\(urls.count)개 열기", "Open \(urls.count) Items") : T("열기", "Open")) { urls.forEach { NSWorkspace.shared.open($0) } }
        add(T("Finder에서 보기", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        add(T("에어드랍", "AirDrop")) { store.airDrop(urls) }
        menu.addItem(.separator())
        add(T("트레이에서 빼기", "Remove from Tray")) { store.remove(ids: Set(selected.map(\.id))) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
