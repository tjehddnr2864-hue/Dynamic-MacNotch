import AppKit
import CryptoKit

/// 자동 업데이트 (GitHub Releases).
/// 실행 30초 뒤와 이후 하루 한 번 최신 릴리스를 확인하고, 새 버전이면 내려받아 검증한 뒤 교체·재실행한다.
/// 검증: ① 릴리스에 함께 올린 SHA-256과 일치 ② 코드 서명 무결성 ③ 같은 번들 ID ④ 지금보다 높은 버전.
/// 하나라도 맞지 않으면 설치하지 않는다. 교체는 앱이 끝난 뒤 별도 셸이 하고, 실패하면 이전 앱을 되돌린다.
final class Updater {
    static let shared = Updater()

    private static let repo = "tjehddnr2864-hue/Dynamic-MacNotch"
    private static let lastCheckKey = "updateLastCheck"
    private let settings = AppSettings.shared
    private var timer: Timer?
    private var busy = false
    /// 상태를 노치에 알리는 처리기 (AppDelegate가 연결)
    var notify: ((_ title: String, _ subtitle: String, _ success: Bool) -> Void)?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfDue() }
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkIfDue() {
        guard settings.autoUpdate else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        check(userInitiated: false)
    }

    /// userInitiated: 메뉴에서 직접 눌렀을 때 — 최신이면 그렇다고 알린다.
    func check(userInitiated: Bool) {
        guard !busy else { return }
        busy = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.performUpdate()
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .installed: break   // 곧 종료·재실행됨
                case .upToDate:
                    if userInitiated {
                        self.notify?(T("최신 버전입니다", "You're up to date"), "Dynamic MacNotch \(Self.currentVersion)", true)
                    }
                case .failed(let reason):
                    if userInitiated { self.notify?(T("업데이트 실패", "Update failed"), reason, false) }
                }
            }
        }
    }

    private enum Result { case installed, upToDate, failed(String) }

    // MARK: - 확인 → 내려받기 → 검증 → 교체

    private func performUpdate() -> Result {
        guard let release = fetchJSON("https://api.github.com/repos/\(Self.repo)/releases/latest"),
              let tag = release["tag_name"] as? String,
              let assets = release["assets"] as? [[String: Any]] else {
            return .failed(T("업데이트 정보를 가져오지 못했습니다", "Couldn't reach GitHub"))
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(latest, than: Self.currentVersion) else { return .upToDate }

        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
                .flatMap { $0.scheme == "https" ? $0 : nil }
        }
        guard let zipURL = asset(".zip"), let shaURL = asset(".zip.sha256"),
              let shaText = download(shaURL).flatMap({ String(data: $0, encoding: .utf8) }),
              let expected = shaText.split(separator: " ").first.map({ String($0).lowercased() }),
              expected.count == 64 else {
            return .failed(T("릴리스 파일이 올바르지 않습니다", "Release files are missing"))
        }
        guard let zip = download(zipURL, limit: 100_000_000) else {
            return .failed(T("내려받기에 실패했습니다", "Download failed"))
        }
        // ① 체크섬
        let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { return .failed(T("체크섬이 일치하지 않습니다", "Checksum mismatch")) }

        // 압축 풀기
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("DynamicMacNotch-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zipFile = work.appendingPathComponent("update.zip")
        guard (try? zip.write(to: zipFile)) != nil,
              run("/usr/bin/ditto", ["-x", "-k", zipFile.path, work.path]) == 0 else {
            return .failed(T("압축을 풀지 못했습니다", "Couldn't unpack the update"))
        }
        let newApp = work.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        // ② 서명 무결성 ③ 같은 앱 ④ 더 높은 버전
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0,
              let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let newVersion = info["CFBundleShortVersionString"] as? String,
              Self.isNewer(newVersion, than: Self.currentVersion) else {
            return .failed(T("업데이트 파일 검증에 실패했습니다", "The update failed verification"))
        }
        // 설치 위치에 쓸 수 있어야 교체할 수 있다
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            DispatchQueue.main.async { NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repo)/releases/latest")!) }
            return .failed(T("앱 폴더에 쓸 권한이 없어 릴리스 페이지를 열었습니다", "No permission to replace the app; opened the release page"))
        }
        DispatchQueue.main.async { self.install(newApp: newApp, target: target, version: newVersion) }
        return .installed
    }

    /// 앱이 끝나면 교체하고 다시 연다. 경로는 모두 셸 인자로 넘긴다 (셸 주입 방지).
    private func install(newApp: URL, target: URL, version: String) {
        notify?(T("업데이트 설치 중", "Installing update"), "Dynamic MacNotch \(version)", true)
        UserDefaults.standard.set(version, forKey: "updateJustInstalled")
        let backup = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).old")
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$4"
        if mv "$2" "$4"; then
          if mv "$3" "$2"; then rm -rf "$4"; else mv "$4" "$2"; fi
        fi
        open "$2"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                          target.path, newApp.path, backup.path]
        do {
            try task.run()
        } catch {
            notify?(T("업데이트 실패", "Update failed"), error.localizedDescription, false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
    }

    /// 업데이트 후 첫 실행이면 알린다.
    func announceIfUpdated() {
        guard let v = UserDefaults.standard.string(forKey: "updateJustInstalled") else { return }
        UserDefaults.standard.removeObject(forKey: "updateJustInstalled")
        guard v == Self.currentVersion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.notify?(T("업데이트 완료", "Updated"), "Dynamic MacNotch \(v)", true)
        }
    }

    // MARK: - 도우미

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func fetchJSON(_ url: String) -> [String: Any]? {
        guard let u = URL(string: url), let data = download(u, accept: "application/vnd.github+json") else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func download(_ url: URL, limit: Int = 5_000_000, accept: String? = nil) -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("DynamicMacNotch/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count <= limit { result = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 120)
        return result
    }

    private func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
