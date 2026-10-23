import AppKit
import SwiftUI

enum MediaSource: String, CaseIterable, Identifiable {
    case all, appleMusic, spotify
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return T("모든 미디어", "All Media")
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }
    var bundleID: String? {
        switch self {
        case .all: return nil
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }
}

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var timestamp: Date
    var rate: Double
    var playing: Bool
    var bundleID: String?
    /// 다음·이전 곡 명령을 받을 수 있는지 (시스템이 알려 준 값. nil이면 알 수 없음)
    var canNext: Bool? = nil
    var canPrev: Bool? = nil

    /// 지금 시점의 재생 위치 (마지막 보고 이후 흐른 시간 반영).
    func position(at now: Date = Date()) -> Double {
        let p = elapsed + (playing ? now.timeIntervalSince(timestamp) * max(rate, playing ? 1 : 0) : 0)
        return duration > 0 ? min(max(0, p), duration) : max(0, p)
    }

    var trackKey: String { "\(title)|\(artist)|\(album)" }
}

/// 현재 재생 중인 미디어 (가이드라인 5.7).
/// 모든 미디어: MediaRemote 어댑터(perl + dylib) · 실패 시 Apple Music/Spotify 분산 알림 + AppleScript로 대체.
final class MediaController: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color = .white
    /// 이전/다음 곡 버튼을 누를 때마다 바뀐다 (확장 팝업 앨범아트 회전 시작 신호). 방향: 다음 +1, 이전 -1
    @Published private(set) var skipToken = 0
    private(set) var skipDirection: Double = 1
    @Published private(set) var adapterRunning = false
    /// 잠금화면 전체화면 배경용 흐린 앨범아트 (처음 필요할 때 한 번 만든다)
    private var backdropCache: (key: ObjectIdentifier, image: CGImage)?

    var artworkBackdrop: CGImage? {
        guard let art = artwork else { return nil }
        let key = ObjectIdentifier(art)
        if let c = backdropCache, c.key == key { return c.image }
        guard let cg = art.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let blurred = ImageScaler.blurredBackdrop(cg) else { return nil }
        backdropCache = (key, blurred)
        return blurred
    }
    /// 즐겨찾기(별) 상태. nil이면 해당 앱이 지원하지 않음 (Apple Music만 지원).
    @Published private(set) var favorited: Bool?

    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private var adapter: Process?
    private var adapterInput: FileHandle?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 1
    private var hideWork: DispatchWorkItem?
    /// 곡이 바뀐 직후 새 앨범아트를 기다리는 곡 변경 팝업 (아트·색이 맞은 뒤에 띄운다)
    private var trackPopupWork: DispatchWorkItem?
    private var artworkDate = Date.distantPast
    private var lastTrackKey: String?
    private var lastArtworkTrack: String?
    private var fallbackActive = false

    init(center: ActivityCenter) {
        self.center = center
    }

    func start() {
        startAdapter()
        // 어댑터가 실패해도 Music/Spotify는 분산 알림으로 받는다.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in
            self?.fallbackNotification(n.userInfo, bundle: "com.apple.Music")
        }
        dnc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            self?.fallbackNotification(n.userInfo, bundle: "com.spotify.client")
        }
        // 재생 위치는 '마지막 보고 시각 + 흐른 시간'으로 계산하므로 앱 전체 타이머가 필요 없다.
        // 진행 바를 그리는 화면만 보이는 동안 스스로 다시 그린다(TimelineView).
    }

    /// 앱 종료 시 어댑터(perl) 하위 프로세스를 함께 끝낸다.
    func stop() {
        adapter?.terminationHandler = nil
        adapter?.terminate()
        adapter = nil
    }

    // MARK: - 어댑터

    private func startAdapter() {
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("libMRAdapter.dylib").path) else {
            fallbackActive = true
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [resources.appendingPathComponent("mr_run.pl").path,
                       resources.appendingPathComponent("libMRAdapter.dylib").path]
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardInput = input
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.adapterRunning = false
                self.fallbackActive = true
                // 재시작 (최대 60초 간격)
                DispatchQueue.main.asyncAfter(deadline: .now() + self.restartDelay) { self.startAdapter() }
                self.restartDelay = min(60, self.restartDelay * 2)
            }
        }
        do {
            try p.run()
            adapter = p
            adapterInput = input.fileHandleForWriting
            adapterRunning = true
            fallbackActive = false
        } catch {
            fallbackActive = true
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            restartDelay = 1
            handleAdapter(obj)
        }
    }

    private func handleAdapter(_ o: [String: Any]) {
        if testActive { return }   // 재생 테스트 중에는 실제 보고를 무시 (끝나면 이전 상태로 되돌림)
        if o["error"] != nil { fallbackActive = true; return }
        let artwork = (o["artwork"] as? String).flatMap { Data(base64Encoded: $0) }
        guard o["empty"] == nil, let title = o["title"] as? String, !title.isEmpty else {
            // 시스템에 재생 중인 앱이 없다고 보고됨.
            // Music·Spotify는 자체 알림으로 상태를 받으므로 그 앱을 보여 주는 중이면 여기서 지우지 않는다.
            if deferred?.np.bundleID.map(Self.trusted.contains) != true { deferred = nil }
            if !fallbackActive, !(nowPlaying?.bundleID.map(Self.trusted.contains) ?? false) { update(nil) }
            if artwork != nil, let np = nowPlaying { receive(np, artwork: artwork) }
            return
        }
        let ts = (o["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let np = NowPlaying(
            title: title,
            artist: o["artist"] as? String ?? "",
            album: o["album"] as? String ?? "",
            duration: o["duration"] as? Double ?? 0,
            elapsed: o["elapsed"] as? Double ?? 0,
            timestamp: ts,
            rate: o["rate"] as? Double ?? 0,
            playing: (o["playing"] as? Bool) ?? ((o["playing"] as? Int) == 1),
            bundleID: o["bundle"] as? String,
            canNext: o["canNext"] as? Bool,
            canPrev: o["canPrev"] as? Bool
        )
        receive(np, artwork: artwork)
    }

    #if DEV
    /// 개발용: 가짜 보고 주입. "adapter|<bundle>|<title>|<playing 0/1>", "adapter-empty", "music|<Playing/Paused/Stopped>|<title>"
    func debugInject(_ spec: String) {
        let p = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch p.first {
        case "adapter" where p.count == 4:
            handleAdapter(["title": p[2], "artist": "Test", "bundle": p[1], "playing": p[3] == "1", "duration": 200.0, "elapsed": 10.0])
        case "adapter-empty":
            handleAdapter(["empty": true])
        case "music" where p.count == 3:
            fallbackNotification(["Player State": p[1], "Name": p[2], "Artist": "Test", "Album": "Test", "Total Time": 200000.0,
                                  "Playback Position": 10.0], bundle: "com.apple.Music")
        default: break
        }
    }

    var debugState: String {
        "\(nowPlaying.map { "\($0.bundleID ?? "?"):\($0.title):\($0.playing ? "playing" : "paused")" } ?? "none") deferred=\(deferred.map { "\($0.np.bundleID ?? "?"):\($0.np.title)" } ?? "-")"
    }
    #endif

    // MARK: - 어떤 앱을 보여 줄지 판정

    /// 자체 분산 알림으로 재생 상태를 알려 주는 앱 (재생 여부를 직접 확인할 수 있음)
    private static let trusted: Set<String> = ["com.apple.Music", "com.spotify.client"]
    /// 먼저 재생 중인 앱 때문에 보류한 다른 앱의 보고 (먼저 앱이 멈추면 이어서 보여 줌)
    private var deferred: (np: NowPlaying, artwork: Data?)?
    private var verifying = false
    private var lastVerify = Date.distantPast

    /// 모든 보고(시스템 Now Playing, Music·Spotify 알림)는 여기서 판정한다.
    /// ① 재생 소스를 Apple Music/Spotify로 정했으면 다른 앱의 보고는 무시한다 (지우지도 않음).
    /// ② 두 앱이 동시에 재생되면 먼저 재생한 앱을 계속 보여 준다. 먼저 앱이 멈추면 보류해 둔 앱으로 넘어간다.
    private func receive(_ np: NowPlaying, artwork: Data?) {
        if testActive { return }
        if let wanted = settings.mediaSource.bundleID, np.bundleID != wanted { return }
        if let cur = nowPlaying, cur.playing, np.playing, cur.bundleID != np.bundleID {
            deferred = (np, artwork ?? deferred.flatMap { $0.np.bundleID == np.bundleID ? $0.artwork : nil })
            if let owner = cur.bundleID, Self.trusted.contains(owner) {
                verifyOwnerStillPlaying(owner)
                return
            }
            // 재생 여부를 확인할 수 없는 앱(브라우저 등)이 먼저였으면 시스템이 알려 준 새 앱으로 넘어간다
        }
        if deferred?.np.bundleID == np.bundleID { deferred = nil }
        apply(np, artwork: artwork)
    }

    private func apply(_ np: NowPlaying?, artwork: Data?) {
        if let artwork { setArtwork(data: artwork) }
        update(np)
    }

    /// 먼저 재생한 Music/Spotify가 아직 재생 중인지 백그라운드에서 확인한다 (앱을 새로 띄우지 않음).
    private func verifyOwnerStillPlaying(_ bundle: String) {
        guard !verifying, Date().timeIntervalSince(lastVerify) > 3 else { return }
        verifying = true
        lastVerify = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = Self.runScript("""
                if application id "\(bundle)" is running then
                    tell application id "\(bundle)" to return (player state as text)
                end if
                return "stopped"
                """)?.stringValue ?? "stopped"
            DispatchQueue.main.async {
                guard let self else { return }
                self.verifying = false
                if state != "playing", self.nowPlaying?.bundleID == bundle { self.promoteDeferred() }
            }
        }
    }

    /// 먼저 재생하던 앱이 멈추면 보류해 둔 앱으로 넘어간다.
    @discardableResult
    private func promoteDeferred() -> Bool {
        guard let d = deferred, d.np.playing else { return false }
        deferred = nil
        apply(d.np, artwork: d.artwork)
        if d.np.bundleID.map(Self.trusted.contains) == true, lastArtworkTrack != d.np.trackKey, let b = d.np.bundleID {
            loadScriptArtwork(bundle: b, key: d.np.trackKey)
        }
        return true
    }

    // MARK: - 대체 경로 (Music / Spotify 분산 알림)

    private func fallbackNotification(_ info: [AnyHashable: Any]?, bundle: String) {
        guard let info else { return }
        let state = info["Player State"] as? String ?? ""
        guard state != "Stopped", let title = info["Name"] as? String else {
            if deferred?.np.bundleID == bundle { deferred = nil }
            if nowPlaying?.bundleID == bundle, !promoteDeferred() { update(nil) }
            return
        }
        // 먼저 재생하던 이 앱이 일시정지되면, 그사이 재생을 시작한 다른 앱으로 넘어간다
        if state != "Playing", nowPlaying?.bundleID == bundle, promoteDeferred() { return }
        // Music은 Total Time(ms), Spotify는 Duration(ms)
        let durationMS = (info["Total Time"] as? Double) ?? (info["Duration"] as? Double) ?? 0
        let key = "\(title)|\(info["Artist"] as? String ?? "")|\(info["Album"] as? String ?? "")"
        // 위치: 알림에 있으면 그 값, 같은 곡을 이미 보고 있으면 계산한 값, 그 밖에만 AppleScript로 묻는다
        let known = nowPlaying.flatMap { $0.bundleID == bundle && $0.trackKey == key ? $0.position(at: Date()) : nil }
        let position = (info["Playback Position"] as? Double) ?? known ?? Self.scriptNumber(bundle: bundle, "player position") ?? 0
        let np = NowPlaying(title: title, artist: info["Artist"] as? String ?? "", album: info["Album"] as? String ?? "",
                            duration: durationMS / 1000, elapsed: position, timestamp: Date(),
                            rate: state == "Playing" ? 1 : 0, playing: state == "Playing", bundleID: bundle)
        receive(np, artwork: nil)
        if nowPlaying?.bundleID == bundle, lastArtworkTrack != np.trackKey { loadScriptArtwork(bundle: bundle, key: np.trackKey) }
    }

    /// 앨범아트 내려받기: HTTPS만, 5초 제한, 10MB 이하만 (백그라운드에서 호출)
    private static func download(_ url: URL) -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpShouldHandleCookies = false
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count <= 10_000_000 { result = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        return result
    }

    private func loadScriptArtwork(bundle: String, key: String) {
        lastArtworkTrack = key
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var artData: Data?
            if bundle == "com.apple.Music" {
                artData = Self.runScript("tell application id \"com.apple.Music\" to get raw data of artwork 1 of current track")?.data
            } else if let url = Self.runScript("tell application id \"com.spotify.client\" to get artwork url of current track")?.stringValue,
                      let u = URL(string: url), u.scheme == "https" {
                artData = Self.download(u)
            }
            DispatchQueue.main.async { if let artData { self?.setArtwork(data: artData) } }
        }
    }

    @discardableResult
    static func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private static func scriptNumber(bundle: String, _ property: String) -> Double? {
        runScript("tell application id \"\(bundle)\" to get \(property)")?.doubleValue
    }

    // MARK: - 상태 반영

    private func accepts(_ np: NowPlaying?) -> Bool {
        guard let np, np.bundleID != Self.testBundle, let wanted = settings.mediaSource.bundleID else { return true }
        return np.bundleID == wanted
    }

    private func update(_ incoming: NowPlaying?) {
        let np = accepts(incoming) ? incoming : nil
        let trackChanged = np != nil && np?.trackKey != lastTrackKey
        nowPlaying = np
        if let np { lastTrackKey = np.trackKey }
        if trackChanged || np?.bundleID != "com.apple.Music" { refreshFavorite() }
        publishActivity(trackChanged: trackChanged)
    }

    /// 앨범아트: 디코딩 → 600px로 축소 → 평균색. 모두 vImage로 처리 (CoreGraphics draw 누수 회피).
    private func setArtwork(data: Data) {
        let decoded: (CGImage, Color)? = autoreleasepool {
            guard let full = ImageScaler.decode(data), let small = ImageScaler.scaled(full, maxPixels: 600) else { return nil }
            return (small, Self.accentColor(small))
        }
        guard let (cg, color) = decoded else { return }
        let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        artwork = image
        accent = color
        artworkDate = Date()
        publishActivity(trackChanged: false)
        // 이미 떠 있는 곡 변경 팝업도 새 아트·색으로 맞춘다
        center.update(.media) {
            $0.tint = color
            $0.artwork = image
        }
        // 새 아트를 기다리던 곡 변경 팝업이 있으면 지금 띄운다
        if let work = trackPopupWork {
            work.cancel()
            trackPopupWork = nil
            postTrackPopup()
        }
    }

    private func publishActivity(trackChanged: Bool) {
        hideWork?.cancel()
        guard let np = nowPlaying else {
            center.removePersistent(.media)
            return
        }
        center.setPersistent(NotchActivity(
            kind: .media, priority: ActivityPriority.media,
            symbol: "music.note", tint: accent,
            value: .waveform(np.playing),
            title: np.title, subtitle: np.artist,
            wing: 46, artwork: artwork
        ))
        if trackChanged, settings.mediaShowTrackChange, np.playing, Date().timeIntervalSince(launchedAt) > 4 {
            trackPopupWork?.cancel()
            trackPopupWork = nil
            if Date().timeIntervalSince(artworkDate) < 0.4 {
                // 새 곡 정보와 함께 아트가 방금 도착함 → 바로 띄운다
                postTrackPopup()
            } else {
                // 아트가 따로 늦게 오는 경우: 이전 곡 아트·색으로 뜨지 않게 잠깐(최대 0.8초) 기다린다
                let work = DispatchWorkItem { [weak self] in
                    self?.trackPopupWork = nil
                    self?.postTrackPopup()
                }
                trackPopupWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            }
        }
        // 일시정지 후 N초 뒤 숨김
        if !np.playing, settings.mediaHideAfterPause > 0 {
            let work = DispatchWorkItem { [weak self] in
                guard self?.nowPlaying?.playing == false else { return }
                self?.center.removePersistent(.media)
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.mediaHideAfterPause, execute: work)
        }
    }

    private func postTrackPopup() {
        guard let np = nowPlaying, np.playing else { return }
        center.post(NotchActivity(
            kind: .media, priority: ActivityPriority.media, presentation: .detail, duration: 2.2,
            symbol: "music.note", tint: accent, value: .waveform(true),
            title: np.title, subtitle: np.artist, detailValue: .waveform(true), artwork: artwork
        ))
    }

    /// 파형·강조에 쓸 앨범아트 평균색. 너무 어두우면 파형이 안 보이므로 밝기를 올린다.
    static func accentColor(_ image: CGImage) -> Color {
        guard let avg = ImageScaler.averageColor(image) else { return .white }
        let c = NSColor(red: avg.r, green: avg.g, blue: avg.b, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(s, 0.8), brightness: max(b, 0.75))
    }

    // MARK: - 제어

    func togglePlayPause() {
        if testActive { testControl { $0.playing.toggle() }; return }
        command("toggle", script: "playpause", mediaKey: 16)
    }
    /// 다음(+1)·이전(-1) 곡으로 넘길 수 있는지. Music·Spotify는 AppleScript로 항상 가능,
    /// 그 밖의 앱은 시스템(MediaRemote)이 '가능'이라고 알려 줄 때만 (영상 한 편만 재생 중이면 보통 불가).
    func canSkip(_ direction: Int) -> Bool {
        guard let np = nowPlaying else { return false }
        if testActive { return true }
        if let b = np.bundleID, Self.trusted.contains(b) { return true }
        return (direction > 0 ? np.canNext : np.canPrev) == true
    }

    func next() {
        if testActive { testSkip(1); return }
        skipDirection = 1
        skipToken &+= 1
        command("next", script: "next track", mediaKey: 17)
    }

    func previous() {
        if testActive { testSkip(-1); return }
        skipDirection = -1
        skipToken &+= 1
        command("prev", script: "previous track", mediaKey: 18)
    }

    func seek(to seconds: Double) {
        if testActive { testControl { $0.elapsed = seconds }; return }
        if let bundle = nowPlaying?.bundleID, ["com.apple.Music", "com.spotify.client"].contains(bundle) {
            DispatchQueue.global().async { Self.runScript("tell application id \"\(bundle)\" to set player position to \(seconds)") }
        } else {
            send("seek \(seconds)")
        }
        if var np = nowPlaying {
            np.elapsed = seconds
            np.timestamp = Date()
            nowPlaying = np
        }
    }

    // MARK: - 즐겨찾기 (Apple Music)

    /// Apple Music 현재 곡의 즐겨찾기 상태를 다시 읽는다 (곡이 바뀔 때, 음악 팝업을 열 때).
    func refreshFavorite() {
        guard nowPlaying?.bundleID == "com.apple.Music" else {
            if favorited != nil { favorited = nil }
            return
        }
        let key = lastTrackKey
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = Self.readFavorite()
            DispatchQueue.main.async {
                // 읽는 사이 곡이 바뀌었으면 버린다
                guard let self, self.lastTrackKey == key, self.nowPlaying?.bundleID == "com.apple.Music" else { return }
                let v = value ?? false
                if self.favorited != v { self.favorited = v }
            }
        }
    }

    /// macOS 14+ Music은 favorited, 이전 버전은 loved
    private static func readFavorite() -> Bool? {
        (runScript("tell application id \"com.apple.Music\" to get favorited of current track")
            ?? runScript("tell application id \"com.apple.Music\" to get loved of current track"))?.booleanValue
    }

    func toggleFavorite() {
        guard let current = favorited else { return }
        favorited = !current   // 바로 반영하고, 실제 값으로 다시 맞춘다
        let key = lastTrackKey
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let v = current ? "false" : "true"
            if Self.runScript("tell application id \"com.apple.Music\" to set favorited of current track to \(v)") == nil {
                Self.runScript("tell application id \"com.apple.Music\" to set loved of current track to \(v)")
            }
            let actual = Self.readFavorite()
            DispatchQueue.main.async {
                guard let self, self.lastTrackKey == key, let actual else { return }
                if self.favorited != actual { self.favorited = actual }
            }
        }
    }

    func openSourceApp() {
        guard let id = nowPlaying?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// Music/Spotify는 AppleScript, 그 외는 어댑터 명령. 어댑터가 없으면 미디어 키를 보낸다.
    private func command(_ adapterCommand: String, script: String, mediaKey: Int) {
        if let bundle = nowPlaying?.bundleID, ["com.apple.Music", "com.spotify.client"].contains(bundle) {
            DispatchQueue.global().async { Self.runScript("tell application id \"\(bundle)\" to \(script)") }
        } else if adapterRunning {
            send(adapterCommand)
        } else {
            Self.postMediaKey(mediaKey)
        }
    }

    private func send(_ line: String) {
        // 어댑터가 막 끝난 경우에도 앱이 죽지 않게 예외를 던지는 쓰기를 쓴다 (SIGPIPE는 main.swift에서 무시)
        try? adapterInput?.write(contentsOf: Data((line + "\n").utf8))
    }

    /// NX_KEYTYPE_PLAY(16) / NEXT(17) / PREVIOUS(18) 키 이벤트를 합성한다.
    static func postMediaKey(_ key: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (key << 16) | ((down ? 0xA : 0xB) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - 재생 테스트 (설정 → 테스트)
    // 실제 음악과 상관없는 가짜 곡을 노치에 띄운다. 조작(재생·다음·이전·이동·노치 호버/열기)이
    // 30초 동안 없으면 스스로 끝나고, 끝나면 타이머·가짜 앨범아트를 모두 놓고 테스트 전 상태로 되돌린다.

    static let testBundle = "com.dynamicmacnotch.test"
    /// 앱을 띄운 시각 (막 시작했을 때 이미 재생 중인 곡은 '곡 변경' 팝업으로 보여 주지 않음)
    private let launchedAt = Date()
    private(set) var testActive = false
    private var testSaved: (np: NowPlaying?, artwork: NSImage?, accent: Color, key: String?)?
    private var testIndex = 0
    private var testIdleTimer: Timer?
    private var testLastInteraction = Date()
    private static let testIdleLimit: TimeInterval = 30
    private static let testTracks: [(title: String, artist: String, hue: Double)] = [
        (T("미리보기 테스트 곡", "Preview Test Song"), "Dynamic MacNotch", 0.58),
        (T("두 번째 테스트 곡", "Second Test Song"), "Dynamic MacNotch", 0.83),
        (T("세 번째 테스트 곡", "Third Test Song"), "Dynamic MacNotch", 0.08),
    ]

    func startTest() {
        guard !testActive else { noteTestInteraction(); return }
        testSaved = (nowPlaying, artwork, accent, lastTrackKey)
        testActive = true
        deferred = nil
        testIndex = 0
        applyTestTrack(playing: true, elapsed: 0)
        noteTestInteraction()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.testLastInteraction) >= Self.testIdleLimit else { return }
            self.stopTest()
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        testIdleTimer = t
    }

    func stopTest() {
        guard testActive else { return }
        testIdleTimer?.invalidate()
        testIdleTimer = nil
        testActive = false
        center.dismissTransient(kind: .media)
        // 테스트 전 상태로 (가짜 곡·앨범아트 참조를 모두 놓는다)
        let saved = testSaved
        testSaved = nil
        artwork = saved?.artwork
        accent = saved?.accent ?? .white
        backdropCache = nil
        nowPlaying = nil
        lastTrackKey = saved?.key
        update(saved?.np)
        MemoryTrim.soon()
    }

    /// 노치 호버·열기, 미디어 조작 때 호출 → 자동 중지까지 남은 시간을 다시 30초로
    func noteTestInteraction() {
        if testActive { testLastInteraction = Date() }
    }

    private func testControl(_ change: (inout NowPlaying) -> Void) {
        guard var np = nowPlaying, np.bundleID == Self.testBundle else { return }
        noteTestInteraction()
        np.elapsed = np.position(at: Date())
        np.timestamp = Date()
        change(&np)
        np.rate = np.playing ? 1 : 0
        update(np)
    }

    private func testSkip(_ direction: Double) {
        noteTestInteraction()
        skipDirection = direction
        skipToken &+= 1
        testIndex = (testIndex + (direction > 0 ? 1 : Self.testTracks.count - 1)) % Self.testTracks.count
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.testActive else { return }
            self.applyTestTrack(playing: true, elapsed: 0)
        }
    }

    private func applyTestTrack(playing: Bool, elapsed: Double) {
        let track = Self.testTracks[testIndex]
        if let cg = Self.testArtwork(hue: track.hue) {
            artwork = NSImage(cgImage: cg, size: NSSize(width: 150, height: 150))
            accent = Self.accentColor(cg)
            backdropCache = nil
        }
        update(NowPlaying(title: track.title, artist: track.artist, album: T("테스트", "Test"), duration: 184,
                          elapsed: elapsed, timestamp: Date(), rate: playing ? 1 : 0, playing: playing,
                          bundleID: Self.testBundle))
    }

    /// 테스트 앨범아트: 300×300 대각선 그라데이션을 픽셀로 직접 만든다 (그리기 API를 쓰지 않음)
    private static func testArtwork(hue: Double) -> CGImage? {
        let size = 300
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        let a = NSColor(hue: hue, saturation: 0.75, brightness: 0.95, alpha: 1).usingColorSpace(.deviceRGB)!
        let b = NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 0.55, alpha: 1)
            .usingColorSpace(.deviceRGB)!
        for y in 0..<size {
            for x in 0..<size {
                let t = CGFloat(x + y) / CGFloat(2 * size - 2)
                let i = (y * size + x) * 4
                pixels[i] = UInt8((a.redComponent * (1 - t) + b.redComponent * t) * 255)
                pixels[i + 1] = UInt8((a.greenComponent * (1 - t) + b.greenComponent * t) * 255)
                pixels[i + 2] = UInt8((a.blueComponent * (1 - t) + b.blueComponent * t) * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

}
