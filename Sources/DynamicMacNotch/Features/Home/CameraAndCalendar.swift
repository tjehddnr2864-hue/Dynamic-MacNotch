import AppKit
import SwiftUI
import AVFoundation
import EventKit

// MARK: - 카메라 (거울)

/// 홈의 카메라 페이지. 페이지가 보이는 동안만 세션을 켜고, 닫히면 즉시 끈다 (초록 표시등 꺼짐).
struct CameraPage: View {
    @ObservedObject var settings = AppSettings.shared
    /// 켜짐 상태는 노치와 공유한다: 켜면 노치가 커지고, 끄거나 노치를 닫거나 다른 페이지로 넘기면 작아진다.
    @ObservedObject var vm: NotchViewModel
    private let statusState = State(initialValue: AVCaptureDevice.authorizationStatus(for: .video))

    private var active: Bool {
        get { vm.cameraOn }
        nonmutating set { withAnimation(vm.openSpring) { vm.cameraOn = newValue } }
    }

    private var status: AVAuthorizationStatus {
        get { statusState.wrappedValue }
        nonmutating set { statusState.wrappedValue = newValue }
    }

    var body: some View {
        if active, status == .authorized {
            CameraPreview(mirror: settings.cameraMirror)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button { active = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        } else {
            Button(action: turnOn) {
                VStack(spacing: 7) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.1))
                        Image(systemName: status == .denied || status == .restricted ? "video.slash.fill" : "video.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .frame(width: 50, height: 50)
                    Text(status == .denied || status == .restricted ? T("카메라 권한 필요", "Camera permission needed") : T("눌러서 카메라 켜기", "Click to turn on camera"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func turnOn() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            active = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    status = AVCaptureDevice.authorizationStatus(for: .video)
                    if granted { active = true }
                }
            }
        default:
            PermissionsManager.shared.openSettings(.camera)
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    var mirror: Bool

    final class PreviewView: NSView {
        let session = AVCaptureSession()
        let layerPreview: AVCaptureVideoPreviewLayer

        override init(frame: NSRect) {
            layerPreview = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: frame)
            wantsLayer = true
            layerPreview.videoGravity = .resizeAspectFill
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(layerPreview)
            session.sessionPreset = .medium
            if let device = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            layerPreview.frame = bounds
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
            } else {
                DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() }
            }
        }

        func setMirror(_ on: Bool) {
            guard let c = layerPreview.connection, c.isVideoMirroringSupported else { return }
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = on
        }
    }

    func makeNSView(context: Context) -> PreviewView {
        let v = PreviewView(frame: .zero)
        v.setMirror(mirror)
        return v
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.setMirror(mirror)
    }

    static func dismantleNSView(_ nsView: PreviewView, coordinator: ()) {
        DispatchQueue.global(qos: .userInitiated).async { nsView.session.stopRunning() }
    }
}

// MARK: - 캘린더

/// 오늘 남은 일정 (가이드라인 5.1). 일정 N분 전에는 노치에 알림을 띄운다.
final class CalendarController: ObservableObject {
    struct Event: Identifiable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var color: Color
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var authorized = false

    private let store = EKEventStore()
    private let center: ActivityCenter
    private let settings = AppSettings.shared
    private var timer: Timer?
    private var alerted = Set<String>()

    init(center: ActivityCenter) {
        self.center = center
    }

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// 설정 → 기본에서 '일정'이 켜져 있는 동안만 일정 변화를 듣고 알림 시각에 깨어난다.
    func start() {
        guard observers.isEmpty else { return }
        observers = [
            (NotificationCenter.default, NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                self?.reload()
            }),
            // 날짜가 바뀌거나 시계가 크게 바뀌면(잠자기 해제 등) 다시 읽는다.
            (NotificationCenter.default, NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                self?.reload()
            }),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.reload()
            }),
        ]
        reload()
    }

    /// 끄기: 듣기·타이머를 모두 멈추고 읽어 둔 일정도 비운다
    func stop() {
        for (nc, token) in observers { nc.removeObserver(token) }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
        events = []
        alerted.removeAll()
    }

    /// 30초마다 다시 읽는 대신, 다음에 할 일이 있는 시각(일정 알림 시각 · 일정 끝 · 자정)에 한 번만 깨어난다.
    private func scheduleNextWake() {
        timer?.invalidate()
        let now = Date()
        var candidates: [Date] = [Calendar.current.startOfDay(for: now).addingTimeInterval(86_400 + 1)]
        let lead = settings.calendarAlertMinutes * 60
        for e in events where !e.allDay {
            if lead > 0, !alerted.contains(e.id), e.start.addingTimeInterval(-lead) > now {
                candidates.append(e.start.addingTimeInterval(-lead))
            }
            if e.end > now { candidates.append(e.end.addingTimeInterval(1)) }
        }
        guard let next = candidates.min() else { return }
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in self?.reload() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    func reload() {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard authorized else { events = []; return }
        let now = Date()
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        let predicate = store.predicateForEvents(withStart: Calendar.current.startOfDay(for: now), end: endOfDay, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .prefix(3)
            .map { e in
                Event(id: e.calendarItemIdentifier, title: e.title ?? T("(제목 없음)", "(No Title)"), start: e.startDate, end: e.endDate,
                      allDay: e.isAllDay, color: Color(nsColor: e.calendar.color ?? .systemBlue))
            }
        checkAlerts()
        scheduleNextWake()
    }

    /// 일정 시작 N분 전 컴팩트 알림 (가이드라인 5.1)
    private func checkAlerts() {
        let minutes = settings.calendarAlertMinutes
        guard minutes > 0 else { return }
        let now = Date()
        for e in events where !e.allDay && !alerted.contains(e.id) {
            let lead = e.start.timeIntervalSince(now)
            guard lead > 0, lead <= minutes * 60 else { continue }
            alerted.insert(e.id)
            center.post(NotchActivity(
                kind: .calendar, priority: ActivityPriority.info, presentation: .detail, duration: 6,
                symbol: "calendar", tint: e.color, value: .text(T("\(Int(ceil(lead / 60)))분 후", "in \(Int(ceil(lead / 60))) min")),
                title: e.title, subtitle: Self.timeText(e)
            ))
        }
    }

    static func timeText(_ e: Event) -> String {
        if e.allDay { return T("하루 종일", "All Day") }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: e.start)) – \(f.string(from: e.end))"
    }

    func open(_ e: Event) {
        let url = URL(string: "ical://ekevent/\(e.id)?method=show&options=more")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        }
    }
}

struct CalendarPage: View {
    @ObservedObject var calendar: CalendarController

    var body: some View {
        if !calendar.authorized {
            VStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 20)).foregroundStyle(.white.opacity(0.8))
                Button(T("캘린더 허용", "Allow Calendar")) { calendar.requestAccess() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        } else if calendar.events.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "calendar.badge.checkmark").font(.system(size: 20)).foregroundStyle(.green)
                Text(T("오늘 남은 일정 없음", "No more events today")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(T("오늘 일정", "Today")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                ForEach(calendar.events) { e in
                    Button { calendar.open(e) } label: {
                        HStack(spacing: 6) {
                            Capsule().fill(e.color).frame(width: 3, height: 24)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(e.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Text(CalendarController.timeText(e)).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
