import SwiftUI
import AppKit

/// 창 뒤 배경을 흐리게 하는 머티리얼 (잠금화면 배경 위 반투명 카드).
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// 잠금화면 미디어 위젯 공용 상태. 카드와 전체화면이 같은 뷰 트리 안에서 matchedGeometry로 이어진다.
final class LockPlayerState: ObservableObject {
    @Published var isFull = false
    @Published var volume: Float = AudioOutput.volume(AudioOutput.defaultDevice()) ?? 0.5
    /// 카드가 놓일 위치 (전체화면 창 좌표, 위쪽 기준)
    @Published var cardRect: CGRect = .zero
}

/// 잠금화면 미디어 위젯 (가이드라인 5.13). 노치가 아닌 별도 카드로, 앨범아트를 누르면 전체화면으로 커진다(iPadOS 참고).
struct LockPlayerView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsProvider
    @ObservedObject var state: LockPlayerState
    @ObservedObject var settings = AppSettings.shared
    var close: () -> Void
    @Namespace private var ns

    private var hideInfo: Bool { settings.lockHideTrackInfo }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if state.isFull {
                    fullBackground
                        .transition(.opacity)
                    fullLayout(size: geo.size)
                        .transition(.opacity)
                } else {
                    card
                        .frame(width: state.cardRect.width, height: state.cardRect.height)
                        .offset(x: state.cardRect.minX, y: state.cardRect.minY)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 카드

    private var card: some View {
        let np = media.nowPlaying
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                artwork(size: 56, radius: 12)
                    .onTapGesture { toggleFull() }
                    .help(T("전체화면으로 보기", "Full Screen"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(hideInfo ? T("재생 중", "Playing") : (np?.title ?? ""))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .matchedGeometryEffect(id: "title", in: ns)
                    if !hideInfo {
                        Text(np?.artist ?? "")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .matchedGeometryEffect(id: "artist", in: ns)
                    }
                }
                Spacer(minLength: 0)
                outputButton
            }
            progress
            transport(size: 1)
            volumeRow
        }
        .padding(18)
        .foregroundStyle(.white)
        .background(VisualEffectBlur().clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }

    // MARK: - 전체화면

    private var fullBackground: some View {
        ZStack {
            Color.black
            if let backdrop = media.artworkBackdrop {
                // 미리 흐리게 만든 작은 앨범아트를 화면 크기로 늘려 천천히 돌린다.
                // (큰 이미지에 실시간 블러를 걸지 않음 · 회전은 Core Animation이 처리)
                BackdropRotation(image: backdrop)
            } else {
                LinearGradient(colors: [media.accent.opacity(0.7), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Color.black.opacity(0.35)
        }
        .ignoresSafeArea()
    }

    private func fullLayout(size: CGSize) -> some View {
        let artSize = min(size.height * 0.46, size.width * 0.3)
        return HStack(alignment: .center, spacing: size.width * 0.06) {
            VStack(alignment: .leading, spacing: 22) {
                artwork(size: artSize, radius: 22)
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
                    .onTapGesture { toggleFull() }
                VStack(alignment: .leading, spacing: 4) {
                    Text(hideInfo ? T("재생 중", "Playing") : (media.nowPlaying?.title ?? ""))
                        .font(.system(size: 26, weight: .bold))
                        .lineLimit(2)
                        .matchedGeometryEffect(id: "title", in: ns)
                    if !hideInfo {
                        Text(media.nowPlaying?.artist ?? "")
                            .font(.system(size: 19))
                            .foregroundStyle(.white.opacity(0.65))
                            .matchedGeometryEffect(id: "artist", in: ns)
                    }
                }
                progress
                transport(size: 1.5)
                volumeRow
            }
            .frame(width: artSize)

            lyricsColumn
                .frame(width: size.width * 0.38, height: size.height * 0.7)
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topTrailing) {
            Button(action: toggleFull) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(36)
        }
    }

    @ViewBuilder
    private var lyricsColumn: some View {
        if hideInfo {
            Color.clear
        } else if media.nowPlaying?.bundleID != "com.apple.Music" {
            placeholder(T("가사는 Apple Music 재생 시 표시됩니다", "Lyrics are shown while playing Apple Music"))
        } else {
            switch lyrics.state {
            case .synced(let lines):
                SyncedLyricsView(lines: lines, media: media, fontSize: lyricsFont)
            case .plain(let lines):
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(lines) { l in
                            Text(l.text).font(.system(size: lyricsFont * 0.8, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        if !settings.lyricsOnline { onlineConsent }
                    }
                    .padding(.vertical, 40)
                }
            case .loading:
                ProgressView().controlSize(.large)
            default:
                VStack(spacing: 16) {
                    placeholder(T("가사가 없습니다", "No lyrics"))
                    if !settings.lyricsOnline { onlineConsent }
                }
            }
        }
    }

    private var onlineConsent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(T("실시간 가사 켜기", "Turn On Live Lyrics")) { settings.lyricsOnline = true; lyricsReload() }
                .buttonStyle(.borderedProminent)
            Text(T("곡 제목·아티스트가 외부 가사 서비스(LRCLIB)로 전송됩니다.", "The song title and artist are sent to an external lyrics service (LRCLIB)."))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func lyricsReload() {
        lyrics.reset()
        lyrics.load(for: media.nowPlaying)
    }

    private var lyricsFont: CGFloat { [22, 28, 34][max(0, min(2, settings.lyricsSize))] }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.5))
    }

    // MARK: - 공용 부품

    private func artwork(size: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let art = media.artwork, !hideInfo {
                Image(uncached: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: size * 0.35)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .matchedGeometryEffect(id: "art", in: ns)
        .contentShape(Rectangle())
    }

    private var progress: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: media.nowPlaying?.playing != true)) { ctx in
            progressBody(now: ctx.date)
        }
        .matchedGeometryEffect(id: "progress", in: ns)
    }

    private func progressBody(now: Date) -> some View {
        let np = media.nowPlaying
        let pos = np?.position(at: now) ?? 0
        let dur = np?.duration ?? 0
        return VStack(spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(Color.white).frame(width: dur > 0 ? g.size.width * min(1, pos / dur) : 0)
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    if dur > 0 { media.seek(to: Double(p.x / g.size.width) * dur) }
                }
            }
            .frame(height: 6)
            HStack {
                Text(MediaPage.time(pos))
                Spacer()
                Text("-" + MediaPage.time(max(0, dur - pos)))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        
    }

    private func transport(size k: CGFloat) -> some View {
        HStack(spacing: 34 * k) {
            CircleIcon(symbol: "backward.fill", size: 30 * k) { media.previous() }
            CircleIcon(symbol: media.nowPlaying?.playing == true ? "pause.fill" : "play.fill", size: 38 * k) { media.togglePlayPause() }
            CircleIcon(symbol: "forward.fill", size: 30 * k) { media.next() }
        }
        .frame(maxWidth: .infinity)
        .matchedGeometryEffect(id: "transport", in: ns)
    }

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").font(.system(size: 10))
            Slider(value: Binding(
                get: { Double(state.volume) },
                set: { v in
                    state.volume = Float(v)
                    AudioOutput.setVolume(AudioOutput.defaultDevice(), Float(v))
                }
            ))
            .controlSize(.mini)
            .tint(.white)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 10))
        }
        .foregroundStyle(.white.opacity(0.6))
        .matchedGeometryEffect(id: "volume", in: ns)
    }

    private var outputButton: some View {
        // 잠금 화면 위에는 메뉴 창을 띄울 수 없으므로 현재 출력 기기 아이콘만 보여 준다.
        OutputIcon()
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 28, height: 28)
    }

    private func toggleFull() {
        if state.isFull {
            close()
        } else {
            lyrics.load(for: media.nowPlaying)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { state.isFull = true }
        }
    }
}

/// 재생 위치에 맞춰 현재 줄을 강조하고 자동 스크롤하는 동기 가사.
struct SyncedLyricsView: View {
    var lines: [LyricsProvider.Line]
    @ObservedObject var media: MediaController
    var fontSize: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { ctx in
            let position = media.nowPlaying?.position(at: ctx.date) ?? 0
            let current = LyricsProvider.currentIndex(lines, at: position)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Color.clear.frame(height: 120)
                        ForEach(lines) { line in
                            let isCurrent = line.id == current
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: fontSize, weight: .bold))
                                .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.35))
                                .blur(radius: isCurrent ? 0 : 0.6)
                                .scaleEffect(isCurrent ? 1.0 : 0.96, anchor: .leading)
                                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isCurrent)
                                .id(line.id)
                                .onTapGesture { if let t = line.time { media.seek(to: t) } }
                        }
                        Color.clear.frame(height: 240)
                    }
                }
                .onChange(of: current) { _, new in
                    guard let new else { return }
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
                        proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.3))
                    }
                }
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                     .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}

/// 흐린 앨범아트 배경: 4분에 한 바퀴 천천히 회전 (Core Animation이 돌려 앱 CPU를 쓰지 않음)
struct BackdropRotation: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> BackdropLayerView { BackdropLayerView() }

    func updateNSView(_ v: BackdropLayerView, context: Context) { v.setImage(image) }
}

final class BackdropLayerView: NSView {
    private let imageLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.minificationFilter = .linear
        imageLayer.magnificationFilter = .linear
        layer?.addSublayer(imageLayer)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 240
        spin.repeatCount = .infinity
        imageLayer.add(spin, forKey: "spin")
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: CGImage) {
        guard imageLayer.contents as! CGImage? !== image else { return }
        imageLayer.contents = image
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 회전해도 모서리가 비지 않게 화면 대각선보다 크게
        let side = hypot(bounds.width, bounds.height) * 1.2
        imageLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}
