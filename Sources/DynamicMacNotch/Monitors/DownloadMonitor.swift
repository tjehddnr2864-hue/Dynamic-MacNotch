import AppKit
import Combine
import SwiftUI

/// 브라우저 다운로드 실시간 표시 (가이드라인 5.8).
/// 시작 시 상세 카드로 크게 떴다가 컴팩트(좌: 브라우저 아이콘, 우: 진행률)로 줄어든다.
final class DownloadMonitor {
    private final class Item {
        let tempURL: URL
        let browserID: String?
        let started = Date()
        var fraction: Double?
        var received: Int64 = 0
        var total: Int64?
        var lastBytes: Int64 = 0
        var lastSample = Date()
        var speed: Double = 0
        var subscriber: Any?

        init(tempURL: URL, browserID: String?) {
            self.tempURL = tempURL
            self.browserID = browserID
        }

        var displayName: String {
            let name = tempURL.lastPathComponent
            for ext in [".download", ".crdownload", ".part"] where name.hasSuffix(ext) {
                return String(name.dropLast(ext.count))
            }
            return name
        }
    }

    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private var items: [URL: Item] = [:]
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pollTimer: Timer?
    private(set) var lastCompleted: URL?

    private static let tempExtensions = ["download": "com.apple.Safari", "crdownload": "com.google.Chrome", "part": "org.mozilla.firefox"]

    init(center: ActivityCenter) {
        self.center = center
    }

    /// 다운로드 폴더 접근은 시스템 허용 창을 띄우므로 권한 창에서 요청한 뒤에만 감시한다.
    func start() {
        if UserDefaults.standard.bool(forKey: "filesPermissionRequested") {
            beginWatching()
            return
        }
        // 주기 확인 대신, 권한 창에서 '파일 및 폴더'를 요청해 설정값이 바뀌는 순간에 감시를 시작한다.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
            guard let self, UserDefaults.standard.bool(forKey: "filesPermissionRequested") else { return }
            if let o = self.defaultsObserver { NotificationCenter.default.removeObserver(o) }
            self.defaultsObserver = nil
            self.beginWatching()
        }
    }

    private var defaultsObserver: NSObjectProtocol?

    private var folders: [URL] {
        var list = [AppSettings.folderURL(settings.downloadFolder, fallback: AppSettings.defaultDownloadFolder)]
        list += AppSettings.list(settings.downloadFolders).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        return list
    }

    private var watchedPaths: [String] = []
    private var folderObserver: AnyCancellable?

    private func beginWatching() {
        // 설정에서 다운로드 폴더·추가 폴더를 바꾸면 감시를 다시 건다
        if folderObserver == nil {
            folderObserver = settings.$downloadFolder.combineLatest(settings.$downloadFolders)
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _, _ in self?.rewatchIfNeeded() }
        }
        watchedPaths = folders.map(\.path)
        for folder in folders {
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            src.setEventHandler { [weak self] in self?.scan() }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
        scan(initial: true)
    }

    private func rewatchIfNeeded() {
        guard folders.map(\.path) != watchedPaths else { return }
        sources.forEach { $0.cancel() }
        sources.removeAll()
        beginWatching()
    }

    // MARK: - 스캔

    /// 다운로드 폴더에 있던 일반 파일 (새로 생긴 파일을 찾기 위해)
    private var knownFiles = Set<String>()
    /// 에어드랍으로 받은 파일이 생기면 호출 (TrayStore가 상태 표시)
    var onAirDropReceived: (([URL]) -> Void)?

    private func scan(initial: Bool = false) {
        var present = Set<URL>()
        var received: [URL] = []
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names {
                let ext = (name as NSString).pathExtension
                guard let browser = Self.tempExtensions[ext] else {
                    // 새 일반 파일: 에어드랍으로 받은 것인지 확인 (받은 파일에는 sharingd 격리 표시가 붙는다)
                    let path = folder.appendingPathComponent(name).path
                    if !knownFiles.contains(path) {
                        knownFiles.insert(path)
                        if !initial, !name.hasPrefix(".") {
                            if Self.isAirDropReceived(path) {
                                received.append(URL(fileURLWithPath: path))
                            } else {
                                // 파일이 먼저 생기고 표시가 나중에 붙는 경우가 있어 1초 뒤 한 번 더 확인한다
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                                    if Self.isAirDropReceived(path) { self?.onAirDropReceived?([URL(fileURLWithPath: path)]) }
                                }
                            }
                        }
                    }
                    continue
                }
                guard settings.downloadEnabled else { continue }
                let url = folder.appendingPathComponent(name)
                present.insert(url)
                if items[url] == nil, !initial {
                    begin(url, browser: Self.resolveBrowser(browser))
                }
            }
        }
        // 사라진 임시 파일 = 완료 또는 취소
        for (url, item) in items where !present.contains(url) {
            finish(item)
        }
        if knownFiles.count > 5000 { knownFiles.removeAll() }   // 아주 큰 폴더에서 집합이 끝없이 커지지 않게
        updatePolling()
        if !received.isEmpty { onAirDropReceived?(received) }
    }

    /// 에어드랍으로 받은 파일은 격리 속성(com.apple.quarantine)의 에이전트가 sharingd다.
    static func isAirDropReceived(_ path: String) -> Bool {
        let name = "com.apple.quarantine"
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return false }
        var buf = [UInt8](repeating: 0, count: size)
        guard getxattr(path, name, &buf, size, 0, 0) == size,
              let value = String(bytes: buf, encoding: .utf8) else { return false }
        return value.localizedCaseInsensitiveContains("sharingd") || value.localizedCaseInsensitiveContains("AirDrop")
    }

    private func begin(_ url: URL, browser: String) {
        let item = Item(tempURL: url, browserID: browser)
        // 브라우저가 Finder 아이콘 진행 바용으로 게시하는 NSProgress를 구독한다.
        item.subscriber = Progress.addSubscriber(forFileURL: url) { [weak item] progress in
            let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
                DispatchQueue.main.async {
                    item?.fraction = p.fractionCompleted
                    if p.totalUnitCount > 1 { item?.total = p.totalUnitCount }
                    item?.received = p.completedUnitCount
                }
            }
            return { observation.invalidate() }
        }
        items[url] = item
        readSafariInfo(item)

        // 처음에는 상세 카드로 크게, 이후 컴팩트
        center.post(NotchActivity(
            kind: .download, priority: ActivityPriority.download, presentation: .detail, duration: 2.5,
            symbol: "arrow.down.circle.fill", tint: .blue, value: progressValue(item),
            title: item.displayName, subtitle: subtitle(item), detailValue: largeValue(item),
            artwork: Self.icon(for: browser)
        ))
        publishPersistent()
    }

    private func finish(_ item: Item) {
        if let s = item.subscriber { Progress.removeSubscriber(s) }
        items[item.tempURL] = nil
        publishPersistent()

        // 완성된 파일: 같은 폴더에서 임시 확장자를 뺀 이름, 없으면 방금 생긴 가장 최신 파일
        let folder = item.tempURL.deletingLastPathComponent()
        var final = folder.appendingPathComponent(item.displayName)
        if !FileManager.default.fileExists(atPath: final.path) {
            let recent = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]))?
                .filter { Self.tempExtensions[$0.pathExtension] == nil }
                .compactMap { u -> (URL, Date)? in
                    let d = (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                    return d >= item.started.addingTimeInterval(-2) ? (u, d) : nil
                }
                .max { $0.1 < $1.1 }
            guard let found = recent?.0 else { return }   // 취소된 다운로드
            final = found
        }
        lastCompleted = final
        center.post(NotchActivity(
            kind: .download, priority: ActivityPriority.info, duration: 3,
            symbol: "checkmark.circle.fill", tint: .green, value: .check,
            title: T("다운로드 완료", "Download Complete"), subtitle: final.lastPathComponent,
            wing: 46, artwork: NSWorkspace.shared.icon(forFile: final.path),
            fileURL: final
        ))
    }

    // MARK: - 진행률 갱신

    private func updatePolling() {
        if items.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
            RunLoop.main.add(t, forMode: .common)
            pollTimer = t
        }
    }

    private func poll() {
        for item in items.values {
            readSafariInfo(item)
            if item.fraction == nil {
                // 진행률을 모르면 파일 크기 증가만 추적 (Firefox 등)
                item.received = Self.size(of: item.tempURL)
            }
            let now = Date()
            let dt = now.timeIntervalSince(item.lastSample)
            if dt >= 1 {
                item.speed = Double(item.received - item.lastBytes) / dt
                item.lastBytes = item.received
                item.lastSample = now
            }
        }
        publishPersistent()
    }

    /// Safari는 .download 번들 안 Info.plist에 받은 바이트/전체 바이트를 기록한다.
    private func readSafariInfo(_ item: Item) {
        guard item.tempURL.pathExtension == "download",
              let dict = NSDictionary(contentsOf: item.tempURL.appendingPathComponent("Info.plist")) else { return }
        let received = (dict["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value ?? 0
        let total = (dict["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value ?? 0
        item.received = received
        if total > 0 {
            item.total = total
            item.fraction = Double(received) / Double(total)
        }
    }

    private func publishPersistent() {
        guard !items.isEmpty else {
            center.removePersistent(.download)
            return
        }
        let list = Array(items.values)
        let known = list.compactMap(\.fraction)
        let overall: Double? = known.count == list.count ? known.reduce(0, +) / Double(known.count) : nil
        let first = list.min { $0.started < $1.started }!
        let value: ActivityValue = overall.map { settings.downloadStyle == .percent ? .percent($0) : .ring($0) } ?? .spinner
        center.setPersistent(NotchActivity(
            kind: .download, priority: ActivityPriority.download,
            symbol: "arrow.down.circle.fill", tint: .blue, value: value,
            title: list.count > 1 ? T("다운로드 \(list.count)개", "\(list.count) Downloads") : first.displayName,
            subtitle: list.count > 1 ? nil : subtitle(first),
            detailValue: overall.map { .ringPercent($0) } ?? .spinner,
            wing: settings.downloadStyle == .percent ? 54 : 46,
            artwork: Self.icon(for: first.browserID)
        ))
        // 같은 종류의 상세 카드가 떠 있으면 값도 갱신
        center.update(.download) { a in
            if a.presentation == .detail {
                a.value = value
                a.detailValue = overall.map { .ringPercent($0) } ?? .spinner
                a.subtitle = list.count > 1 ? T("다운로드 \(list.count)개", "\(list.count) Downloads") : subtitle(first)
            }
        }
    }

    // MARK: - 표시 도우미

    private func progressValue(_ item: Item) -> ActivityValue {
        guard let f = item.fraction else { return .spinner }
        return settings.downloadStyle == .percent ? .percent(f) : .ring(f)
    }

    private func largeValue(_ item: Item) -> ActivityValue {
        item.fraction.map { .ringPercent($0) } ?? .spinner
    }

    private func subtitle(_ item: Item) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        var parts: [String] = []
        if let id = item.browserID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            parts.append(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
        if let total = item.total {
            parts.append("\(fmt.string(fromByteCount: item.received)) / \(fmt.string(fromByteCount: total))")
        } else if item.received > 0 {
            parts.append(fmt.string(fromByteCount: item.received))
        }
        if item.speed > 0 { parts.append("\(fmt.string(fromByteCount: Int64(item.speed)))/s") }
        return parts.joined(separator: " · ")
    }

    /// .crdownload는 Chrome·Edge·Brave·Arc가 함께 쓰므로 실행 중인 브라우저를 고른다.
    private static func resolveBrowser(_ fallback: String) -> String {
        guard fallback == "com.google.Chrome" else { return fallback }
        let candidates = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser"]
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return candidates.first { running.contains($0) } ?? fallback
    }

    static func clearIconCache() { iconCache.removeAll() }

    /// 브라우저 아이콘은 한 번 만든 이미지를 재사용한다.
    /// 진행률이 바뀔 때마다 새 이미지를 만들면 아이콘이 매번 다시 그려져 깜빡인다.
    private static var iconCache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let id = bundleID else { return nil }
        if let cached = iconCache[id] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[id] = image
        return image
    }

    private static func size(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func revealLastCompleted() {
        if let url = lastCompleted {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let folder = folders.first {
            NSWorkspace.shared.open(folder)
        }
    }
}

/// 다운로드 확장 팝업 (음악 팝업과 같은 구성):
/// 1줄 브라우저 아이콘 · 파일명 · 브라우저/크기/속도 / 2줄 진행 바 · 퍼센트
struct DownloadPage: View {
    var activity: NotchActivity

    private var fraction: Double? {
        switch activity.detailValue ?? activity.value {
        case .ringPercent(let f), .ring(let f), .percent(let f), .bar(let f): return f
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Group {
                    if let art = activity.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "arrow.down.circle.fill").resizable().foregroundStyle(.blue)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(text: activity.title ?? T("다운로드", "Download"), font: .systemFont(ofSize: 14, weight: .semibold), color: .white)
                        .frame(height: 18)
                    Text(activity.subtitle ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                if let url = activity.fileURL {
                    // 다운로드 완료: 받은 위치를 Finder로 연다
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.blue)
                            Text(T("Finder에서 보기", "Show in Finder"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer(minLength: 0)
                            Text(url.deletingLastPathComponent().lastPathComponent)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.1), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else if let f = fraction {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.2))
                            Capsule().fill(Color.blue).frame(width: max(6, geo.size.width * min(1, f)))
                        }
                    }
                    .frame(height: 6)
                    Text("\(Int((f * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: 40, alignment: .trailing)
                } else {
                    SpinnerRing(tint: .blue).frame(width: 16, height: 16)
                    Text(T("진행률 확인 중", "Checking progress"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 0)
                }
            }
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.85), value: fraction)
        }
        .padding(.top, 4)
    }
}
