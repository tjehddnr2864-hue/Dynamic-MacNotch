import SwiftUI

/// 음악 재생 팝업 (기본 팝업과 독립). 참고 이미지 구성:
/// 1줄 앨범아트 · 흐르는 제목 · 아티스트 · 파형 / 2줄 경과 시간 · 진행 바 · 전체 시간 / 3줄 즐겨찾기 · 이전 · 재생 · 다음 · 출력 기기
/// (출력 기기를 길게 누르면 4줄 음량 바가 펼쳐진다)
struct MediaPage: View {
    @ObservedObject var media: MediaController
    var volumeShown = false
    var toggleVolume: () -> Void = {}
    private let scrubState = State(initialValue: Double?.none)

    private var scrub: Double? {
        get { scrubState.wrappedValue }
        nonmutating set { scrubState.wrappedValue = newValue }
    }

    var body: some View {
        if let np = media.nowPlaying {
            VStack(spacing: 11) {
                header(np)
                progress(np)
                controls(np)
                if volumeShown {
                    VolumeRow()
                        // 팝업이 한 줄만큼 늘어나는 동안 위(조작 버튼 줄)에서 내려오듯 나타난다
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .opacity))
                }
            }
            .padding(.top, 4)
            .onAppear { media.refreshFavorite() }   // Music 앱에서 바꾼 즐겨찾기도 반영
            // 위쪽 정렬: 공용 앨범아트 레이어가 계산하는 위치(노치 아래 10pt)와 맞춘다
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 20)).foregroundStyle(.white.opacity(0.5))
                Text(T("재생 중인 미디어가 없습니다", "Nothing is playing")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // MARK: - 1줄: 앨범아트 · 제목 · 아티스트 · 파형

    private func header(_ np: NowPlaying) -> some View {
        HStack(spacing: 12) {
            Button { media.openSourceApp() } label: {
                Group {
                    if media.artwork != nil {
                        Color.clear   // 공용 앨범아트 레이어(NotchRootView)가 이 자리에 그린다
                    } else {
                        ZStack {
                            Color.white.opacity(0.12)
                            Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(T("앱 열기", "Open App"))

            VStack(alignment: .leading, spacing: 3) {
                MarqueeText(text: np.title, font: .systemFont(ofSize: 15, weight: .semibold), color: .white)
                    .frame(height: 19)
                Text(np.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            WaveformView(playing: np.playing, tint: media.accent)
                .frame(width: 22, height: 16)
                .padding(.bottom, 18)
        }
    }

    // MARK: - 2줄: 시간 · 진행 바

    /// 진행 바는 이 화면이 보이는 동안·재생 중일 때만 0.5초마다 다시 그린다 (앱 전체 타이머 없음).
    private func progress(_ np: NowPlaying) -> some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !np.playing || scrub != nil)) { ctx in
            progressBody(np, now: ctx.date)
        }
    }

    private func progressBody(_ np: NowPlaying, now: Date) -> some View {
        let position = scrub ?? np.position(at: now)
        let fraction = np.duration > 0 ? min(1, position / np.duration) : 0
        return ScrubBar(fraction: fraction, enabled: np.duration > 0, onScrub: { f in
            scrub = f * np.duration
        }, onEnd: {
            if let s = scrub { media.seek(to: s) }
            scrub = nil
        }, leading: {
            Text(Self.time(position))
        }, trailing: {
            Text(Self.time(np.duration))
        })
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
    }

    // MARK: - 3줄: 즐겨찾기 · 이전 · 재생 · 다음 · 출력 기기

    private func controls(_ np: NowPlaying) -> some View {
        HStack {
            CircleIcon(symbol: "star.fill", size: 30,
                       tint: media.favorited == true ? .yellow : .white.opacity(media.favorited == nil ? 0.25 : 0.55)) {
                media.toggleFavorite()
            }
                .disabled(media.favorited == nil)
                .animation(.easeOut(duration: 0.2), value: media.favorited)
                .help(media.favorited == nil ? T("이 앱은 즐겨찾기를 지원하지 않습니다", "This app doesn't support favorites") : T("즐겨찾기", "Favorite"))
            Spacer()
            CircleIcon(symbol: "backward.fill", size: 34) { media.previous() }
            Spacer()
            CircleIcon(symbol: np.playing ? "pause.fill" : "play.fill", size: 40) { media.togglePlayPause() }
                .contentTransition(.symbolEffect(.replace))
            Spacer()
            CircleIcon(symbol: "forward.fill", size: 34) { media.next() }
            Spacer()
            OutputPickerButton(onLongPress: toggleVolume)
        }
        .padding(.horizontal, 4)
    }

    static func time(_ t: Double) -> String {
        let s = Int(max(0, t))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// 4줄: 음량 바 (스피커 아이콘을 누르면 음소거, 바를 끌거나 눌러 조절, 스크롤로도 조절)
struct VolumeRow: View {
    @ObservedObject private var route = OutputRoute.shared
    var thickness: CGFloat = 5
    private let dragState = State(initialValue: Float?.none)

    private var dragging: Float? {
        get { dragState.wrappedValue }
        nonmutating set { dragState.wrappedValue = newValue }
    }

    var body: some View {
        let enabled = route.volume != nil
        let level = route.muted ? 0 : (dragging ?? route.volume ?? 0)
        ScrubBar(fraction: Double(level), enabled: enabled, spacing: 10, thickness: thickness, onScrub: { f in
            dragging = Float(f)
            route.setVolume(Float(f))
        }, onEnd: {
            dragging = nil
        }, leading: {
            Button { route.toggleMute() } label: {
                Image(systemName: route.muted || level == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }, trailing: {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
        })
        .foregroundStyle(.white.opacity(enabled ? 0.6 : 0.25))
        .opacity(enabled ? 1 : 0.6)
        .padding(.horizontal, 4)
        .help(enabled ? T("음량", "Volume") : T("이 출력 기기는 음량을 조절할 수 없습니다", "This output device has no volume control"))
    }
}

/// 재생·음량 바. 커서를 올리면 바가 위아래로 살짝 굵어지고,
/// 누른 채 조절하는 동안에는 더 굵어지며 좌우로도 늘어나 양옆 아이콘·글자가 바깥으로 조금 밀려난다.
struct ScrubBar<Leading: View, Trailing: View>: View {
    var fraction: Double
    var enabled = true
    var spacing: CGFloat = 8
    /// 평소 바 두께 (마우스를 올리면 +2, 누르면 +4)
    var thickness: CGFloat = 5
    var onScrub: (Double) -> Void
    var onEnd: () -> Void
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    private let hoverState = State(initialValue: false)
    private let pressState = State(initialValue: false)
    private var hovering: Bool {
        get { hoverState.wrappedValue }
        nonmutating set { hoverState.wrappedValue = newValue }
    }
    private var pressing: Bool {
        get { pressState.wrappedValue }
        nonmutating set { pressState.wrappedValue = newValue }
    }

    /// 누르는 동안 바가 좌우로 늘어나는 양 (한쪽)
    static var pressGrow: CGFloat { 6 }

    var body: some View {
        let barHeight: CGFloat = thickness + (pressing ? 4 : (hovering && enabled ? 2 : 0))
        HStack(spacing: spacing) {
            leading()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    Capsule().fill(Color.white)
                        .frame(width: max(barHeight + 1, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                }
                .frame(height: barHeight)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard enabled, geo.size.width > 0 else { return }
                        if !pressing { pressing = true }
                        onScrub(Double(min(max(0, v.location.x / geo.size.width), 1)))
                    }
                    .onEnded { _ in
                        pressing = false
                        onEnd()
                    })
            }
            .frame(height: max(14, thickness + 9))
            trailing()
        }
        // 누르는 동안 줄 전체가 좌우로 늘어나 바가 길어지고 양옆 요소가 바깥으로 밀려난다
        .padding(.horizontal, pressing ? -Self.pressGrow : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: pressing)
    }
}

/// 폭을 넘는 제목은 오른쪽에서 왼쪽으로 흐르고, 양끝은 부드럽게 사라진다.
struct MarqueeText: View {
    var text: String
    var font: NSFont
    var color: Color
    var gap: CGFloat = 36
    var speed: CGFloat = 28   // pt/초

    var body: some View {
        GeometryReader { geo in
            let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
            if textWidth <= geo.size.width {
                label.frame(width: geo.size.width, alignment: .leading)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let cycle = textWidth + gap
                    // 한 바퀴마다 1.2초 쉬었다가 흐른다.
                    let period = Double(cycle / speed) + 1.2
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
                    let offset = -CGFloat(max(0, t - 1.2)) * speed
                    HStack(spacing: gap) {
                        label
                        label
                    }
                    .fixedSize()
                    .offset(x: offset)
                    .frame(width: geo.size.width, alignment: .leading)
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                             .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
            }
        }
        .clipped()
    }

    private var label: some View {
        Text(text).font(Font(font)).foregroundStyle(color).lineLimit(1).fixedSize()
    }
}

struct CircleIcon: View {
    var symbol: String
    var size: CGFloat = 26
    var tint: Color = .white
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.55, weight: .bold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
    }
}


/// 공용 앨범아트. 확장된 음악 팝업에서 곡이 바뀌면 세로축으로 돌아가며 새 아트로 바뀐다.
/// 다음 곡은 왼쪽으로, 이전 곡은 오른쪽으로 돈다. 버튼을 누르면 바로 돌기 시작해 옆면(90°)에서 새 아트를 기다리고,
/// 새 아트가 오면 반대쪽에서 돌아 들어온다. 버튼 없이 곡이 바뀌면(자동 넘김 등) 아트가 바뀔 때 한 번에 돈다.
struct MediaArtView: View {
    @ObservedObject var media: MediaController
    var size: CGSize
    var flipEnabled: Bool

    private final class Flip {
        enum Phase { case idle, turningAway, waiting }
        var phase = Phase.idle
        var direction: Double = 1
        var artArrived = false
        var timeout: DispatchWorkItem?
    }

    private let angleState = State(initialValue: 0.0)
    private let heldState = State(initialValue: NSImage?.none)
    private let flip = State(initialValue: Flip())

    private var angle: Double {
        get { angleState.wrappedValue }
        nonmutating set { angleState.wrappedValue = newValue }
    }
    /// 돌아가는 동안 붙잡아 두는 이전 곡 아트 (nil이면 현재 아트)
    private var held: NSImage? {
        get { heldState.wrappedValue }
        nonmutating set { heldState.wrappedValue = newValue }
    }

    private static let awayDuration = 0.17
    private static let maxWait = 1.0

    var body: some View {
        Group {
            if let art = held ?? media.artwork {
                Image(uncached: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: size.width * 0.22, style: .continuous))
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        .onChange(of: media.skipToken) { _, _ in
            guard flipEnabled else { return }
            turnAway(direction: media.skipDirection, holding: media.artwork)
        }
        .onChange(of: media.artwork) { old, _ in
            let f = flip.wrappedValue
            guard flipEnabled else { reset(); return }
            switch f.phase {
            case .turningAway:
                f.artArrived = true          // 다 돌아간 뒤 바로 들어온다
            case .waiting:
                turnIn()
            case .idle:
                // 버튼 없이 곡이 바뀜: 이전 아트를 붙잡고 한 번에 돈다
                f.artArrived = true
                turnAway(direction: 1, holding: old)
            }
        }
        .onChange(of: flipEnabled) { _, enabled in
            if !enabled { reset() }
        }
    }

    private func turnAway(direction: Double, holding image: NSImage?) {
        let f = flip.wrappedValue
        guard f.phase == .idle else { return }
        f.phase = .turningAway
        f.direction = direction
        held = image
        // 다음 곡: 왼쪽 가장자리가 안쪽으로 들어가며 돈다
        withAnimation(.easeIn(duration: Self.awayDuration)) {
            angle = -90 * direction
        } completion: {
            guard f.phase == .turningAway else { return }
            if f.artArrived {
                turnIn()
            } else {
                f.phase = .waiting
                let work = DispatchWorkItem { if f.phase == .waiting { turnIn() } }
                f.timeout = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxWait, execute: work)
            }
        }
    }

    private func turnIn() {
        let f = flip.wrappedValue
        f.timeout?.cancel()
        f.timeout = nil
        f.artArrived = false
        f.phase = .idle
        held = nil
        // 반대쪽 옆면에서 새 아트가 돌아 들어온다
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { angle = 90 * f.direction }
        withAnimation(.spring(duration: 0.34, bounce: 0.22)) { angle = 0 }
    }

    private func reset() {
        let f = flip.wrappedValue
        f.timeout?.cancel()
        f.timeout = nil
        f.artArrived = false
        f.phase = .idle
        if held != nil { held = nil }
        if angle != 0 { angle = 0 }
    }
}
