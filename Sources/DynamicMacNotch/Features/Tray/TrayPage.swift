import AppKit
import SwiftUI

// MARK: - 트레이 페이지 (좁은 확장 영역)

struct TrayPage: View {
    @ObservedObject var store: TrayStore
    @ObservedObject var vm: DisplayNotchState

    private static let columns = 3
    private static let cellSize: CGFloat = 46
    private static let spacing: CGFloat = 6
    private static let gridSpace = "trayViewport"

    var body: some View {
        if (vm.isFileDragging && !vm.shared.trayItemDragActive) || store.items.isEmpty {
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

            grid
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // 트레이 파일을 트레이 안에 놓은 경우는 아무 일도 없던 것으로 한다
            guard !vm.shared.trayItemDragActive else { return false }
            store.lastDrop = Date()
            TrayStore.loadURLs(providers) { store.add($0) }
            return true
        }
    }

    // MARK: 파일 격자 (빈 곳을 끌면 사각형 선택)

    private let marqueeState = State(initialValue: CGRect?.none)
    private let marqueeBase = State(initialValue: TrayMarqueeBox())

    private var grid: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cellSize), spacing: Self.spacing), count: Self.columns), spacing: Self.spacing) {
                            ForEach(store.items) { item in
                                TrayItemView(item: item, store: store, vm: vm).id(item.id)
                            }
                        }
                        .frame(width: viewport.size.width)
                        if let rect = marqueeState.wrappedValue {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.25))
                                .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1))
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: viewport.size.height, alignment: .top)
                    .background(
                        Color.black.opacity(0.001)
                            .gesture(marqueeGesture(width: viewport.size.width, height: viewport.size.height, proxy: proxy))
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.gridSpace)).minY } action: {
                        marqueeBase.wrappedValue.contentTop = $0
                    }
                }
                .coordinateSpace(name: Self.gridSpace)
                .background(TrayKeyCatcher(store: store, columns: Self.columns))
                .onChange(of: store.picked.cursor) { _, cursor in
                    // 키보드로 움직인 파일이 보이도록 (사각형 선택은 따로 스크롤한다)
                    guard let cursor, marqueeState.wrappedValue == nil else { return }
                    proxy.scrollTo(cursor)
                }
            }
        }
    }

    /// 파일 칸의 자리. 격자는 가운데 정렬이고 칸 크기가 고정이라 계산으로 구한다 (아직 그려지지 않은 칸도 선택되도록).
    private func cellFrame(_ index: Int, width: CGFloat) -> CGRect {
        let step = Self.cellSize + Self.spacing
        let gridWidth = CGFloat(Self.columns) * step - Self.spacing
        return CGRect(x: (width - gridWidth) / 2 + CGFloat(index % Self.columns) * step,
                      y: CGFloat(index / Self.columns) * step, width: Self.cellSize, height: Self.cellSize)
    }

    private func marqueeGesture(width: CGFloat, height: CGFloat, proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                let box = marqueeBase.wrappedValue
                if box.start == nil {
                    // ⇧·⌘를 누르고 시작하면 기존 선택에 더한다
                    let mods = NSEvent.modifierFlags
                    box.base = mods.contains(.shift) || mods.contains(.command) ? store.selection : []
                    box.start = CGPoint(x: value.startLocation.x, y: value.startLocation.y - box.contentTop)
                    store.requestKeyFocus?()
                }
                guard let start = box.start, hypot(value.translation.width, value.translation.height) > 2 else { return }
                let current = CGPoint(x: value.location.x, y: value.location.y - box.contentTop)
                let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                                  width: abs(current.x - start.x), height: abs(current.y - start.y))
                marqueeState.wrappedValue = rect
                let hit = store.items.indices.filter { cellFrame($0, width: width).intersects(rect) }
                store.selectByMarquee(hit: hit.map { store.items[$0].id }, base: box.base)
                // 커서가 위아래 끝을 넘으면 그쪽 줄이 보이도록 스크롤한다
                let row = max(0, Int(current.y / (Self.cellSize + Self.spacing)))
                let index = min(row * Self.columns, store.items.count - 1)
                if value.location.y > height - 6 {
                    proxy.scrollTo(store.items[index].id, anchor: .bottom)
                } else if value.location.y < 6 {
                    proxy.scrollTo(store.items[index].id, anchor: .top)
                }
            }
            .onEnded { _ in
                let box = marqueeBase.wrappedValue
                // 끌지 않고 빈 곳을 누른 것이면 선택 해제
                if marqueeState.wrappedValue == nil { store.clearSelection() }
                marqueeState.wrappedValue = nil
                box.start = nil
                box.base = []
            }
    }
}

/// 사각형 선택 중에만 쓰는 값 (바뀌어도 화면을 다시 그릴 필요가 없다)
final class TrayMarqueeBox {
    var start: CGPoint?
    var base = Set<UUID>()
    var contentTop: CGFloat = 0
}

/// 트레이의 키보드 조작. 파일이나 빈 곳을 누르면 입력을 받기 시작하고, 노치가 닫히면 돌려준다.
struct TrayKeyCatcher: NSViewRepresentable {
    var store: TrayStore
    var columns: Int

    func makeNSView(context: Context) -> TrayKeyNSView { TrayKeyNSView() }

    func updateNSView(_ v: TrayKeyNSView, context: Context) {
        v.store = store
        v.columns = columns
        store.requestKeyFocus = { [weak v] in v?.takeFocus() }
    }
}

final class TrayKeyNSView: NSView {
    weak var store: TrayStore?
    var columns = 3

    override var acceptsFirstResponder: Bool { true }
    /// 아래의 파일·빈 곳이 마우스를 받도록 키 입력만 맡는다
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func takeFocus() {
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let store else { return super.keyDown(with: event) }
        let mods = event.modifierFlags
        let shift = mods.contains(.shift), command = mods.contains(.command)
        let direction: TraySelection.Direction?
        switch event.keyCode {
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        case 0 where command:   // ⌘A
            store.selectAll()
            return
        case 53 where !store.selection.isEmpty:   // Esc
            store.clearSelection()
            return
        default:
            return super.keyDown(with: event)
        }
        if let direction { store.moveSelection(direction, columns: columns, shift: shift, command: command) }
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
    var vm: DisplayNotchState

    var body: some View {
        let url = store.url(for: item)
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
        .overlay(TrayItemInteraction(item: item, store: store, vm: vm))
        .help(url.lastPathComponent)
    }
}

/// 트레이 파일 하나의 마우스 처리 (SwiftUI의 onDrag는 파일 하나만 끌 수 있어 AppKit 드래그 세션을 쓴다)
struct TrayItemInteraction: NSViewRepresentable {
    var item: TrayStore.Item
    var store: TrayStore
    var vm: DisplayNotchState

    func makeNSView(context: Context) -> TrayItemNSView { TrayItemNSView() }

    func updateNSView(_ v: TrayItemNSView, context: Context) {
        v.item = item
        v.store = store
        v.vm = vm
    }
}

final class TrayItemNSView: NSView, NSDraggingSource {
    var item: TrayStore.Item?
    weak var store: TrayStore?
    weak var vm: DisplayNotchState?
    private var downEvent: NSEvent?
    private var draggedIDs = Set<UUID>()
    /// 드래그를 시작할 때 노치 창의 자리 (끄는 동안 이 줄이 화면에서 빠질 수 있다)
    private var panelFrame = CGRect.zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let item, let store else { return }
        store.requestKeyFocus?()
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
        panelFrame = window?.frame ?? .zero
        store.isDraggingItems = true
        vm?.shared.trayItemDragActive = true
        let session = beginDraggingSession(with: dragItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 원본 파일을 참조하므로 다른 곳에는 복사로 넘긴다
        context == .outsideApplication ? [.copy, .generic] : []
    }

    /// 다른 앱(Finder·메일 등)에 놓는 데 성공했을 때만 트레이에서 뺀다. 노치 위에 놓으면 그대로 둔다.
    /// macOS는 드래그를 시작할 때 양쪽 경우를 모두 물어보므로 위 함수로 놓은 곳을 판단할 수 없다. 놓은 자리로 판단한다.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        #if DEV
        TrayDragLog.write("ended op=\(operation.rawValue) point=\(screenPoint) notch=\(isOnNotch(screenPoint))")
        #endif
        if operation != [], !isOnNotch(screenPoint), let store { store.remove(ids: draggedIDs) }
        draggedIDs.removeAll()
        store?.isDraggingItems = false
        vm?.shared.trayItemDragActive = false
    }

    private func isOnNotch(_ point: NSPoint) -> Bool {
        guard let size = vm?.interactiveSize else { return false }
        return CGRect(x: panelFrame.midX - size.width / 2, y: panelFrame.maxY - size.height, width: size.width, height: size.height).contains(point)
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
        let urls = selected.map(store.url(for:))
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

#if DEV
/// 개발용: 드래그가 어떻게 끝났는지 기록한다 (`$TMPDIR/dmn-traydrag.txt`)
enum TrayDragLog {
    static func write(_ line: String) {
        let path = NSTemporaryDirectory() + "dmn-traydrag.txt"
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
