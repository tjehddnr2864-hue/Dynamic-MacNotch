import Foundation

/// Apple Music 재생 곡의 가사 (가이드라인 5.13).
/// Apple Music의 시간 동기 가사는 공개 API가 없으므로
/// ① (동의 시) 외부 가사 DB LRCLIB의 LRC → ② Music 앱의 정적 가사(`lyrics of current track`) → ③ 없음 순으로 쓴다.
final class LyricsProvider: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id: Int
        let time: Double?   // 정적 가사는 nil
        let text: String
    }

    enum State: Equatable {
        case idle, loading, synced([Line]), plain([Line]), none
    }

    @Published private(set) var state: State = .idle
    private var currentKey: String?
    private var cache: [String: State] = [:]
    private let settings = AppSettings.shared

    private static let cacheFolder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Dynamic MacNotch/Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// 설정이 바뀌었을 때 다시 불러오도록 현재 곡 캐시를 비운다.
    func reset() {
        if let key = currentKey {
            cache[key] = nil
            try? FileManager.default.removeItem(at: Self.diskURL(key))
        }
        currentKey = nil
    }

    func load(for np: NowPlaying?) {
        guard settings.lyricsEnabled, let np, np.bundleID == "com.apple.Music" else {
            currentKey = nil
            state = .none
            return
        }
        let key = np.trackKey
        guard key != currentKey else { return }
        currentKey = key
        if let cached = cache[key] ?? Self.readDisk(key) {
            state = cached
            return
        }
        state = .loading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var result: State = .none
            if self.settings.lyricsOnline, let lines = Self.fetchLRCLIB(np) {
                result = lines
            } else if let plain = Self.musicAppLyrics(), !plain.isEmpty {
                result = .plain(plain)
            }
            DispatchQueue.main.async {
                // 메모리 캐시는 최근 20곡까지만 (오래된 곡은 디스크 캐시에서 다시 읽음)
                if self.cache.count >= 20 { self.cache.removeAll() }
                self.cache[key] = result
                Self.writeDisk(key, result)
                if self.currentKey == key { self.state = result }
            }
        }
    }

    /// 현재 재생 위치에 해당하는 줄 번호 (동기 가사일 때만).
    static func currentIndex(_ lines: [Line], at position: Double) -> Int? {
        var index: Int?
        for (i, l) in lines.enumerated() {
            guard let t = l.time else { continue }
            if t <= position + 0.25 { index = i } else { break }
        }
        return index
    }

    // MARK: - LRCLIB (https://lrclib.net)

    private static func fetchLRCLIB(_ np: NowPlaying) -> State? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            URLQueryItem(name: "track_name", value: np.title),
            URLQueryItem(name: "artist_name", value: np.artist),
            URLQueryItem(name: "album_name", value: np.album),
            URLQueryItem(name: "duration", value: String(Int(np.duration.rounded()))),
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("DynamicMacNotch/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (https://github.com/tjehddnr2864-hue/Dynamic-MacNotch)", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { body = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let synced = json["syncedLyrics"] as? String, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = json["plainLyrics"] as? String, !plain.isEmpty {
            return .plain(plainLines(plain))
        }
        return nil
    }

    /// "[mm:ss.xx] 가사" 형식
    static func parseLRC(_ text: String) -> [Line] {
        var lines: [Line] = []
        let pattern = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = pattern.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let content = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                lines.append(Line(id: 0, time: min * 60 + sec, text: content))
            }
        }
        return lines.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
            .enumerated().map { Line(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }

    private static func plainLines(_ text: String) -> [Line] {
        text.components(separatedBy: .newlines).enumerated().map { Line(id: $0.offset, time: nil, text: $0.element) }
    }

    // MARK: - Music 앱 정적 가사

    private static func musicAppLyrics() -> [Line]? {
        guard let text = MediaController.runScript("tell application id \"com.apple.Music\" to get lyrics of current track")?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return plainLines(text)
    }

    // MARK: - 디스크 캐시

    private static func diskURL(_ key: String) -> URL {
        let safe = key.data(using: .utf8)!.base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return cacheFolder.appendingPathComponent(String(safe.prefix(120)) + ".json")
    }

    private struct Stored: Codable { var synced: Bool; var times: [Double?]; var texts: [String] }

    private static func writeDisk(_ key: String, _ state: State) {
        let lines: [Line], synced: Bool
        switch state {
        case .synced(let l): lines = l; synced = true
        case .plain(let l): lines = l; synced = false
        default: return
        }
        let stored = Stored(synced: synced, times: lines.map(\.time), texts: lines.map(\.text))
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: diskURL(key)) }
    }

    private static func readDisk(_ key: String) -> State? {
        guard let data = try? Data(contentsOf: diskURL(key)),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        let lines = zip(s.times, s.texts).enumerated().map { Line(id: $0.offset, time: $0.element.0, text: $0.element.1) }
        return s.synced ? .synced(lines) : .plain(lines)
    }
}
