import AppKit
import ImageIO
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// 스크린샷 미리보기 (가이드라인 5.11). 스크린샷이 클립보드(또는 파일)로 들어오면
/// 노치가 상세 카드로 커지며 썸네일과 [복사] [저장] [삭제]를 보여 준다. 썸네일은 끌어서 첨부할 수 있다.
final class ScreenshotMonitor: ObservableObject {
    struct Shot {
        var image: NSImage?     // 받은 원본 이미지 (카드 표시에는 쓰지 않음, 곧바로 버림)
        var thumb: CGImage?     // 카드에 그리는 작은 썸네일 (NSImage를 거치지 않아 AppKit 이미지 캐시에 남지 않음)
        var data: Data          // 원본 PNG/TIFF 데이터
        var date: Date
        var fileURL: URL?       // 파일로 저장된 스크린샷일 때
        var pasteboardCount: Int?
        /// 설정 → 테스트의 미리보기 (복사·저장·삭제가 실제로 일어나지 않음)
        var isPreview = false
    }

    @Published private(set) var shot: Shot?
    @Published private(set) var status: String?

    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var ownChangeCount = -1
    private var timer: Timer?
    private var query: NSMetadataQuery?
    private let startedAt = Date()
    private(set) var lastSaved: URL?

    init(center: ActivityCenter) {
        self.center = center
    }

    func start() {
        // ⌘⇧3/4/5 캡처는 스크린샷 도구가 '앱'으로 실행되지 않는 경우가 많아 실행 알림으로는 감지할 수 없다.
        // 클립보드 변경 번호(changeCount)만 0.5초마다 확인한다: 프로세스 간 정수 하나 읽기라 CPU 부담이 거의 없다.
        lastChangeCount = NSPasteboard.general.changeCount
        settings.$screenshotEnabled.combineLatest(settings.$screenshotSource)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled, source in
                self?.updatePasteboardWatch(enabled && source != .file)
                self?.updateFileQuery(source)
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func updatePasteboardWatch(_ on: Bool) {
        if on, timer == nil {
            lastChangeCount = NSPasteboard.general.changeCount
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollPasteboard() }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !on {
            timer?.invalidate()
            timer = nil
        }
    }

    private func updateFileQuery(_ source: ScreenshotSource) {
        if source == .clipboard {
            query?.stop()
            query = nil
        } else if query == nil {
            startFileQuery()
        }
    }

    // MARK: - 클립보드 감지

    /// 스크린샷이 클립보드에 넣는 형식은 이미지(PNG·TIFF)뿐이다.
    /// 브라우저·앱에서 복사한 이미지는 URL·HTML·앱 전용 형식이 함께 들어가므로 이것으로 구별한다.
    private static let screenshotTypes: Set<String> = ["public.png", "Apple PNG pasteboard type", "public.tiff",
                                                       "NeXT TIFF v4.0 pasteboard type"]

    private static func looksLikeScreenshot(_ pb: NSPasteboard) -> Bool {
        guard let items = pb.pasteboardItems, items.count == 1, let types = pb.types, !types.isEmpty else { return false }
        return types.allSatisfy { screenshotTypes.contains($0.rawValue) }
    }

    private func pollPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard settings.screenshotEnabled, settings.screenshotSource != .file,
              pb.changeCount != ownChangeCount, Self.looksLikeScreenshot(pb) else { return }
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), let image = NSImage(data: data) else { return }
        present(Shot(image: image, data: data, date: Date(), fileURL: nil, pasteboardCount: pb.changeCount))
    }

    // MARK: - 파일 감지

    private func startFileQuery() {
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        q.searchScopes = [Self.systemScreenshotFolder]
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { [weak self] n in
            guard let self, self.settings.screenshotEnabled, self.settings.screenshotSource != .clipboard else { return }
            let added = n.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            for item in added {
                guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                let url = URL(fileURLWithPath: path)
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                      let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { continue }
                let date = (item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date) ?? Date()
                guard date > self.startedAt else { continue }
                self.present(Shot(image: image, data: data, date: date, fileURL: url, pasteboardCount: nil))
            }
        }
        q.start()
        query = q
    }

    /// 시스템 스크린샷 저장 위치 (`com.apple.screencapture location`, 기본 데스크탑).
    static var systemScreenshotFolder: URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return URL(fileURLWithPath: (loc as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// 개발용: 현재 클립보드 이미지를 스크린샷처럼 띄운다.
    func debugPresentClipboard() {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), let image = NSImage(data: data) else { return }
        present(Shot(image: image, data: data, date: Date(), fileURL: nil, pasteboardCount: pb.changeCount))
    }

    // MARK: - 카드

    private func present(_ s: Shot) {
        // 카드에는 작은 썸네일만 쓴다. 원본(전체 화면이면 디코딩 시 수십 MB)은 저장·복사용 데이터로만 보관.
        var shot = s
        shot.thumb = Self.thumbnail(from: s.data)
        shot.image = nil
        self.shot = shot
        status = nil
        observeCardEnd()
        center.post(NotchActivity(
            kind: .screenshot, priority: ActivityPriority.screenshot, presentation: .detail,
            duration: settings.screenshotAutoClose,
            symbol: "camera.viewfinder", tint: .white, value: .none,
            title: T("스크린샷", "Screenshot"), detailHeight: 96
        ))
    }

    private var cardWatch: AnyCancellable?

    /// 카드가 저절로 닫혀도(시간 초과) 스크린샷 데이터를 메모리에서 내린다.
    private func observeCardEnd() {
        cardWatch = center.$transient
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                guard let self, t?.kind != .screenshot else { return }
                self.shot = nil
                self.cardWatch = nil
            }
    }

    /// 작은 썸네일 (vImage로 축소 · CoreGraphics draw 누수 회피, ImageScaler 참고)
    static func thumbnail(from data: Data, maxPixels: Int = 480) -> CGImage? {
        autoreleasepool {
            guard let full = ImageScaler.decode(data) else { return nil }
            return ImageScaler.scaled(full, maxPixels: maxPixels)
        }
    }

    private func dismiss(after delay: TimeInterval = 0.8) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.center.transient?.kind == .screenshot else { return }
            self.center.dismissTransient()
            self.shot = nil
        }
    }

    // MARK: - 동작

    /// 미리보기 카드의 버튼: 실제 파일·클립보드는 건드리지 않고 상태만 보여 준다.
    private func previewOnly(_ label: String) -> Bool {
        guard shot?.isPreview == true else { return false }
        status = label
        dismiss()
        return true
    }

    /// 설정 → 테스트: 가짜 이미지로 스크린샷 카드를 띄운다.
    func presentPreview() {
        let size = 320
        var pixels = [UInt8](repeating: 255, count: size * 200 * 4)
        for y in 0..<200 {
            for x in 0..<size {
                let i = (y * size + x) * 4
                pixels[i] = UInt8(40 + x * 120 / size)
                pixels[i + 1] = UInt8(90 + y * 100 / 200)
                pixels[i + 2] = 200
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: size, height: 200, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        present(Shot(image: nil, thumb: nil, data: png, date: Date(), fileURL: nil, pasteboardCount: nil, isPreview: true))
    }

    /// 미리보기 카드가 떠 있으면 바로 닫는다.
    func endPreview() {
        guard shot?.isPreview == true else { return }
        if center.transient?.kind == .screenshot { center.dismissTransient() }
        shot = nil
        status = nil
    }

    func copy() {
        if previewOnly(T("복사됨", "Copied")) { return }
        guard let s = shot else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let url = s.fileURL { pb.writeObjects([url as NSURL]) }
        pb.setData(pngData(s), forType: .png)
        ownChangeCount = pb.changeCount
        lastChangeCount = pb.changeCount
        status = T("복사됨", "Copied")
        dismiss()
    }

    func save() {
        if previewOnly(T("저장됨", "Saved")) { return }
        guard let s = shot else { return }
        let folder = settings.screenshotFolder.isEmpty
            ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            : URL(fileURLWithPath: (settings.screenshotFolder as NSString).expandingTildeInPath)
        let url = Self.uniqueURL(in: folder, base: Self.fileName(for: s.date), ext: settings.screenshotJPEG ? "jpg" : "png")
        do {
            try encoded(s).write(to: url)
            lastSaved = url
            status = T("저장됨", "Saved")
            dismiss()
        } catch {
            status = T("저장 실패", "Save Failed")
        }
    }

    func delete() {
        if previewOnly(T("삭제됨", "Deleted")) { return }
        guard let s = shot else { return }
        let pb = NSPasteboard.general
        if let count = s.pasteboardCount, pb.changeCount == count { pb.clearContents() }
        if let url = s.fileURL { NSWorkspace.shared.recycle([url]) }   // 휴지통으로 (영구 삭제 아님)
        status = T("삭제됨", "Deleted")
        dismiss(after: 0.5)
    }

    /// 드래그로 첨부할 임시 파일 (스크린샷_년도_월_일_시_분_초.png).
    func dragProvider() -> NSItemProvider {
        guard let s = shot else { return NSItemProvider() }
        if let url = s.fileURL { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DynamicMacNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.fileName(for: s.date) + ".png")
        try? pngData(s).write(to: url)
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    // MARK: - 파일 이름·인코딩

    /// 스크린샷_년도_월_일_시_분_초 (24시간제, 두 자리 0 채움)
    static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy_MM_dd_HH_mm_ss"
        return T("스크린샷_", "Screenshot_") + f.string(from: date)
    }

    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)_\(n).\(ext)")
            n += 1
        }
        return url
    }

    private func pngData(_ s: Shot) -> Data {
        if s.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return s.data }   // 이미 PNG
        return NSBitmapImageRep(data: s.data)?.representation(using: .png, properties: [:]) ?? s.data
    }

    private func encoded(_ s: Shot) -> Data {
        guard settings.screenshotJPEG else { return pngData(s) }
        return NSBitmapImageRep(data: s.data)?.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) ?? s.data
    }
}

/// 노치 상세 카드 안의 스크린샷 미리보기.
struct ScreenshotCard: View {
    static let emptyImage: CGImage = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    @ObservedObject var monitor: ScreenshotMonitor
    var notchSize: CGSize

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchSize.height)
            HStack(spacing: 14) {
                if let shot = monitor.shot {
                    Image(decorative: shot.thumb ?? Self.emptyImage, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 150, maxHeight: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.15)))
                        .onDrag { monitor.dragProvider() }
                        .help(T("끌어서 다른 앱에 첨부", "Drag to attach in another app"))
                }
                Spacer(minLength: 0)
                if let status = monitor.status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    HStack(spacing: 10) {
                        action("doc.on.doc", T("복사", "Copy")) { monitor.copy() }
                        action("square.and.arrow.down", T("저장", "Save")) { monitor.save() }
                        action("trash", T("삭제", "Delete"), tint: .red) { monitor.delete() }
                    }
                }
            }
            .padding(.horizontal, 35)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 14)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: monitor.status)
        }
    }

    private func action(_ symbol: String, _ title: String, tint: Color = .white, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: Circle())
                Text(title).font(.system(size: 10))
            }
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}
