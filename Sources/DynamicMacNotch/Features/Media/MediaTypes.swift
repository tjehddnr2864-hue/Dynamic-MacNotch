import AppKit
import SwiftUI

// 미디어 설정 선택지와 재생 정보

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
