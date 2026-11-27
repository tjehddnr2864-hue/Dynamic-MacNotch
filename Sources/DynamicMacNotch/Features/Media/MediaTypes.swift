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

/// 브라우저에서 재생 중인 것이 YouTube인지. macOS의 재생 정보에는 사이트 주소가 없어,
/// 손쉬운 사용 권한으로 그 앱의 창·탭 제목을 읽어 가린다 (YouTube는 "… - YouTube", YouTube Music은 "… | YouTube Music").
enum YouTubeSite: Equatable {
    case music, video, other

    /// YouTube Music 데스크탑 앱
    static let musicApps: Set<String> = ["com.github.th-ch.youtube-music", "com.ytmdesktop.ytmdesktop"]
    /// 창·탭 제목을 볼 필요가 없는 앱
    static let notBrowsers: Set<String> = ["com.apple.Music", "com.spotify.client", "com.apple.TV", "com.apple.podcasts", "com.apple.QuickTimePlayerX"]

    /// 전용 앱이면 바로 안다. 브라우저 등이면 nil (창·탭 제목을 봐야 함).
    static func fromApp(bundleID: String) -> YouTubeSite? {
        if musicApps.contains(bundleID) { return .music }
        if notBrowsers.contains(bundleID) { return .other }
        return nil
    }

    /// 제목 하나의 종류
    static func kind(ofTitle title: String) -> YouTubeSite {
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "youtube music" || t.hasSuffix("| youtube music") || t.hasSuffix("- youtube music") { return .music }
        if t == "youtube" || t.hasSuffix("- youtube") { return .video }
        return .other
    }

    /// 창·탭 제목들에서 지금 곡이 재생 중인 것을 찾는다.
    /// 곡 이름이 들어간 YouTube 제목을 먼저 보고, 없으면 열린 YouTube의 종류로 짐작한다.
    static func fromTitles(_ titles: [String], title: String, album: String) -> YouTubeSite {
        var music = false, video = false, matched: YouTubeSite?
        let wanted = title.trimmingCharacters(in: .whitespaces).lowercased()
        for t in titles {
            let kind = kind(ofTitle: t)
            guard kind != .other else { continue }
            if kind == .music { music = true } else { video = true }
            if !wanted.isEmpty, t.lowercased().contains(wanted) { matched = matched ?? kind }
        }
        if let matched { return matched }
        if music && video { return album.isEmpty ? .video : .music }
        return music ? .music : video ? .video : .other
    }

    /// 앱의 창 제목과 탭 제목 (손쉬운 사용 권한 필요, 메뉴는 보지 않음). 백그라운드에서 부른다.
    static func windowAndTabTitles(pid: pid_t, limit: Int = 4000) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        var titles: [String] = [], stack = [AXUIElementCreateApplication(pid)], visited = 0
        while let element = stack.popLast(), visited < limit {
            visited += 1
            func value(_ name: String) -> CFTypeRef? {
                var v: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, name as CFString, &v) == .success ? v : nil
            }
            let role = value(kAXRoleAttribute) as? String ?? ""
            if role == "AXMenuBar" { continue }
            if role == "AXWindow" || role == "AXRadioButton" || role == "AXTab" || role == "AXTabButton",
               let text = [value(kAXTitleAttribute), value(kAXDescriptionAttribute)].compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
                titles.append(text)
            }
            if let children = value(kAXChildrenAttribute) as? [AXUIElement] { stack += children }
        }
        return titles
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
