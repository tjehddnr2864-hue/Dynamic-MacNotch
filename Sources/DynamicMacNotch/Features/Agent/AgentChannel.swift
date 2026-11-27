import Foundation

/// 에이전트 훅 → 본 앱 통로 (작업 완료·실시간 작업).
///
/// 분산 알림은 같은 사용자의 다른 프로세스도 받을 수 있으므로, 사용자의 글(요청·명령·작업 이름·프로젝트)은 싣지 않는다.
/// 내용은 이 사용자만 읽을 수 있는 폴더(0700)의 파일(0600)로 남기고, 알림에는 그 파일의 id만 싣는다.
/// 본 앱이 읽으면 바로 지운다. 읽히지 않은 파일(앱이 꺼져 있던 동안 등)은 앱이 켜질 때 지운다.
enum AgentChannel {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Dynamic MacNotch/agent-events", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// 내용을 파일로 남기고 id만 알린다 (훅 쪽)
    static func post(_ name: Notification.Name, object: String, payload: [String: Any], in folder: URL = folder) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let id = UUID().uuidString
        let url = folder.appendingPathComponent("\(id).json")
        // 만들 때부터 이 사용자만 읽게 한다 (쓰고 나서 권한을 바꾸면 그 사이에 읽힐 수 있음)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        DistributedNotificationCenter.default().postNotificationName(name, object: object, userInfo: ["id": id], deliverImmediately: true)
    }

    /// 알림의 id로 내용을 읽고 파일을 지운다 (본 앱 쪽). id가 UUID가 아니면 읽지 않는다 (다른 경로를 가리키지 못하게).
    static func take(_ note: Notification, in folder: URL = folder) -> [String: Any]? {
        guard let id = note.userInfo?["id"] as? String, UUID(uuidString: id) != nil else { return nil }
        let url = folder.appendingPathComponent("\(id).json")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 오래된 파일 지우기 (앱이 켜질 때). 반환: 지운 개수
    @discardableResult
    static func sweep(_ folder: URL, olderThan age: TimeInterval, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var removed = 0
        for name in names where name.hasSuffix(".json") {
            let url = folder.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if now.timeIntervalSince(modified) > age, (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: 민감한 글 가리기

    /// 명령·요청에 섞인 비밀번호·토큰·키를 가린다 (노치에 보이는 글, 보관하는 글 모두)
    static func redact(_ text: String) -> String {
        var s = text
        for (pattern, template) in redactions {
            s = pattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    private static let redactions: [(NSRegularExpression, String)] = [
        // Authorization: Bearer xxx / Basic xxx
        (#"(?i)(authorization\s*[:=]\s*(?:bearer|basic|token)?\s*)[^\s"']+"#, "$1•••"),
        // --password=xxx, token=xxx, api_key: xxx, secret xxx …
        (#"(?i)((?:--?)?(?:password|passwd|pwd|token|secret|api[_-]?key|access[_-]?key|client[_-]?secret)\s*[=:]\s*)[^\s"'&]+"#, "$1•••"),
        // URL 안의 사용자:비밀번호@
        (#"(://[^/\s:@]+:)[^@\s/]+@"#, "$1•••@"),
        // 잘 알려진 키 모양
        (#"\b(sk-(?:ant-|proj-)?[A-Za-z0-9_\-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abpr]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{30,})"#, "•••"),
    ].compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }
}
