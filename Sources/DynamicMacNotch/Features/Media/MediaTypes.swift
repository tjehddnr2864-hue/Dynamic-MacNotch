import AppKit
import SwiftUI

// 미디어 설정 선택지와 재생 정보

/// 재생 소스. `all`은 예전 설정(`mediaSource`)의 값으로만 남아 있고, 지금은 `mediaSources` 목록이 비어 있으면 모든 미디어다.
enum MediaSource: String, CaseIterable, Identifiable {
    case all, appleMusic, spotify, youtube
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return T("모든 미디어", "All Media")
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .youtube: return "YouTube"
        }
    }
    var bundleID: String? {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .all, .youtube: return nil
        }
    }

    /// 하나씩 켜고 끄는 소스 (설정 화면 순서)
    static let pickable: [MediaSource] = [.appleMusic, .spotify, .youtube]

    /// 켜거나 끈 뒤의 목록. 비면 모든 미디어. 모든 미디어를 켜면 비운다.
    static func toggled(_ source: MediaSource, on: Bool, in list: [MediaSource]) -> [MediaSource] {
        if source == .all { return [] }
        return pickable.filter { $0 == source ? on : list.contains($0) }
    }
}

/// 재생 소스 YouTube에서 보일 범위
enum YouTubeScope: String, CaseIterable, Identifiable {
    case all, music
    var id: String { rawValue }
    var label: String { self == .all ? T("모든 YouTube", "All of YouTube") : T("YouTube Music만", "YouTube Music only") }
}

/// 브라우저에서 재생 중인 것이 YouTube인지. macOS의 재생 정보에는 주소가 없어 브라우저의 탭 주소·제목으로 가린다.
enum YouTubeSite: Equatable {
    case music, video, other

    /// 브라우저 (탭 주소를 물을 수 있는 것). Firefox는 탭 주소를 알려 주지 않아 없다.
    static let safariLike: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static let chromiumLike: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.microsoft.edgemac",
                                            "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
                                            "org.chromium.Chromium"]
    /// YouTube Music 데스크탑 앱
    static let musicApps: Set<String> = ["com.github.th-ch.youtube-music", "com.ytmdesktop.ytmdesktop"]

    /// 웹 앱(Dock에 추가한 사이트)이나 전용 앱이면 이름으로 바로 안다. 브라우저면 nil (탭을 물어야 함).
    static func fromApp(bundleID: String, name: String?) -> YouTubeSite? {
        if musicApps.contains(bundleID) { return .music }
        if safariLike.contains(bundleID) || chromiumLike.contains(bundleID) || bundleID.hasPrefix("com.apple.WebKit") { return nil }
        guard bundleID.hasPrefix("com.apple.Safari.WebApp") || bundleID.contains(".app.") else { return .other }
        let n = (name ?? "").lowercased()
        return n.contains("youtube music") ? .music : n.contains("youtube") ? .video : .other
    }

    /// 탭 목록("주소<TAB>제목" 줄)에서 지금 곡이 재생 중인 탭을 찾는다.
    /// 제목에 곡 이름이 들어간 YouTube 탭을 먼저 보고, 없으면 YouTube 탭의 종류로 짐작한다.
    static func fromTabs(_ text: String, title: String, album: String) -> YouTubeSite {
        var music = false, video = false, matched: YouTubeSite?
        let wanted = title.trimmingCharacters(in: .whitespaces).lowercased()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let host = parts.first.flatMap({ URL(string: $0)?.host?.lowercased() }) else { continue }
            let kind: YouTubeSite
            if host == "music.youtube.com" { kind = .music } else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be" { kind = .video } else { continue }
            if kind == .music { music = true } else { video = true }
            if !wanted.isEmpty, parts.count > 1, parts[1].lowercased().contains(wanted) { matched = matched ?? kind }
        }
        if let matched { return matched }
        if music && video { return album.isEmpty ? .video : .music }
        return music ? .music : video ? .video : .other
    }

    /// 탭 주소·제목을 묻는 AppleScript (실행 중인 브라우저에만, 3초 제한)
    static func tabScript(bundleID: String) -> String? {
        let titleKey: String
        if safariLike.contains(bundleID) { titleKey = "name" } else if chromiumLike.contains(bundleID) { titleKey = "title" } else { return nil }
        return """
        set out to ""
        with timeout of 3 seconds
        tell application id "\(bundleID)"
        repeat with w in windows
        repeat with t in tabs of w
        try
        set out to out & (URL of t) & tab & (\(titleKey) of t) & linefeed
        end try
        end repeat
        end repeat
        end tell
        end timeout
        return out
        """
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
