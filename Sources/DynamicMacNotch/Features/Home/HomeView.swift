import SwiftUI

/// 확장 상태 홈: 카메라 · 타이머 · 오늘 일정 · 에어드랍/트레이를 한 번에 하나씩 보여 준다.
/// 노치 바깥 아래의 점 4개를 누르거나 두 손가락으로 좌우 스와이프해 넘긴다.
struct HomePager: View {
    @ObservedObject var vm: NotchViewModel
    let timer: TimerController
    var pages: HomePages? = nil

    var body: some View {
        ZStack {
            page(vm.homeOption)
                .id(vm.homeOption)
                .transition(pageTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(x: vm.swipeOffset)
    }

    private var pageTransition: AnyTransition { Self.pageTransition(forward: vm.pageForward) }

    /// 페이지 넘김 전환 (홈·상시 항목 팝업 공통)
    static func pageTransition(forward: Bool) -> AnyTransition {
        let blur = AnyTransition.modifier(active: BlurModifier(radius: 6), identity: BlurModifier(radius: 0))
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity).combined(with: blur),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity).combined(with: blur)
        )
    }

    @ViewBuilder
    private func page(_ option: HomeOption) -> some View {
        switch option {
        case .timer:
            TimerPage(timer: timer)
        case .camera:
            if let pages { pages.camera } else { PlaceholderPage(option: option, note: T("3단계에서 구현", "Not available")) }
        case .usage:
            if let pages { pages.usage } else { PlaceholderPage(option: option, note: T("3단계에서 구현", "Not available")) }
        case .calendar:
            if let pages { pages.calendar } else { PlaceholderPage(option: option, note: T("3단계에서 구현", "Not available")) }
        case .tray:
            if let pages { pages.tray } else { PlaceholderPage(option: option, note: T("3단계에서 구현", "Not available")) }
        }
    }
}

/// 3단계 기능 페이지 묶음 (AppDelegate가 주입).
struct HomePages {
    var camera: AnyView
    var usage: AnyView
    var calendar: AnyView
    var tray: AnyView
}

/// 상시 표시 항목 팝업의 페이지 점 (홈 점과 같은 모양, 우선순위 순)
struct PersistentDots: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(vm.persistentPages, id: \.self) { kind in
                let selected = vm.expandedPage == .activity(kind)
                Button { vm.selectPersistentPage(kind) } label: {
                    Capsule()
                        .fill(Color.white.opacity(selected ? 0.95 : 0.35))
                        .frame(width: selected ? 14 : 6, height: 6)
                        .frame(width: 20, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(vm.openSpring, value: vm.expandedPage)
    }
}

/// 전용 화면이 없는 상시 항목(핫스팟·집중 모드 등)의 팝업: 아이콘 · 이름 · 설명 · 값
struct PersistentInfoPage: View {
    var activity: NotchActivity

    var body: some View {
        HStack(spacing: 12) {
            ActivityLeading(activity: activity, size: 30)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let sub = activity.subtitle, !sub.isEmpty {
                    Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            ActivityValueView(value: activity.detailValue ?? activity.value, tint: activity.tint, large: true,
                              textColor: activity.valueTint)
        }
        .frame(maxHeight: .infinity)
    }
}

/// 확장된 노치 바깥에 따로 떠 있는 페이지 점. 선택된 점은 가로로 길어진다.
struct PageDots: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeOption.allCases, id: \.self) { option in
                let selected = vm.expandedPage == .home && option == vm.homeOption
                Button { vm.selectHomeOption(option) } label: {
                    Capsule()
                        .fill(Color.white.opacity(selected ? 0.95 : 0.35))
                        .frame(width: selected ? 14 : 6, height: 6)
                        .frame(width: 20, height: 16)   // 누르기 쉬운 영역
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.title)
            }
        }
        .animation(vm.openSpring, value: vm.homeOption)
        .animation(vm.openSpring, value: vm.expandedPage)
    }
}

/// 타이머 페이지. 시·분·초 칸에 커서를 올리고 두 손가락으로 위아래로 쓸어 시간을 맞춘다.
struct TimerPage: View {
    @ObservedObject var timer: TimerController

    var body: some View {
        if timer.isActive {
            VStack(spacing: 8) {
                ZStack {
                    RingGauge(value: timer.progress, tint: .orange, lineWidth: 5)
                    Text(TimerController.format(timer.remaining))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .frame(width: 72, height: 72)
                HStack(spacing: 12) {
                    CircleButton(symbol: timer.isPaused ? "play.fill" : "pause.fill", tint: .orange, size: 30) {
                        timer.isPaused ? timer.resume() : timer.pause()
                    }
                    CircleButton(symbol: "xmark", tint: .gray, size: 30) { timer.cancel() }
                }
            }
        } else {
            draftView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 입력 중에 검은 배경을 누르면 입력한 숫자로 확정 (빈칸이면 00)
                .background {
                    if timer.editingUnit != nil {
                        Color.black.opacity(0.001).onTapGesture { timer.finishEditing() }
                    }
                }
                .onAppear { timer.draftVisible = true }
                .onDisappear {
                    timer.finishEditing()
                    timer.draftVisible = false
                    timer.hoveredUnit = nil
                }
        }
    }

    private var draftView: some View {
            VStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(TimerController.Unit.allCases, id: \.self) { unit in
                        if unit != .hour {
                            Text(":").font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.bottom, 14)
                        }
                        unitColumn(unit)
                    }
                }
                Button {
                    timer.finishEditing()   // 입력 중이던 숫자부터 반영
                    timer.startDraft()
                } label: {
                    Label(T("시작", "Start"), systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(timer.draftSeconds > 0 ? 0.85 : 0.3), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(timer.draftSeconds == 0 && timer.editingUnit == nil)
            }
    }

    private func unitColumn(_ unit: TimerController.Unit) -> some View {
        let hovered = (timer.hoveredUnit ?? timer.selectedUnit) == unit
        let editing = timer.editingUnit == unit
        return VStack(spacing: 1) {
            Group {
                if editing {
                    // 키보드로 직접 입력: 두 자리를 치면 다음 칸으로, Enter는 완료, Esc는 취소, Tab은 다음 칸
                    TimerDigitField(timer: timer, unit: unit)
                } else {
                    RollingText(text: String(format: "%02d", timer.draft[unit.rawValue]), up: timer.lastStepUp)
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 40, height: 34)
            .background(Color.white.opacity(editing ? 0.22 : (hovered ? 0.14 : 0.05)), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(editing ? 0.9 : 0), lineWidth: 1.5))
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.8), value: timer.draft[unit.rawValue])
            Text(unit.label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(hovered ? 0.9 : 0.45))
        }
        .contentShape(Rectangle())
        .onTapGesture { timer.beginEditing(unit) }
        .onHover { inside in
            if inside { timer.hoveredUnit = unit } else if timer.hoveredUnit == unit { timer.hoveredUnit = nil }
        }
        .help(T("눌러서 숫자 입력 · 두 손가락으로 위아래로 쓸어 조절", "Click to type · Two-finger swipe up/down to adjust"))
    }
}

/// 타이머 숫자 입력 칸. 노치 창은 이 칸을 누를 때만 키보드를 받는다.
struct TimerDigitField: NSViewRepresentable {
    @ObservedObject var timer: TimerController
    var unit: TimerController.Unit

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TimerDigitField
        var finished = false
        init(_ parent: TimerDigitField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let digits = String(field.stringValue.filter(\.isNumber).prefix(2))
            if digits != field.stringValue { field.stringValue = digits }
            if digits.count == 2 { advance(field, next: true) }   // 두 자리 입력 → 다음 칸
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                advance(field, next: false)
                return true
            case #selector(NSResponder.insertTab(_:)):
                advance(field, next: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finished = true
                parent.timer.endEditing()
                return true
            default:
                return false
            }
        }

        /// 바깥 클릭·시작 버튼 등으로 확정 (TimerController.finishEditing)
        func commitFromOutside(_ field: NSTextField, emptyAsZero: Bool) {
            guard !finished else { return }
            finished = true
            parent.timer.commitEdit(parent.unit, text: field.stringValue, emptyAsZero: emptyAsZero)
            parent.timer.endEditing()
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard !finished, let field = note.object as? NSTextField else { return }
            finished = true
            parent.timer.commitEdit(parent.unit, text: field.stringValue)
            parent.timer.endEditing()
        }

        private func advance(_ field: NSTextField, next: Bool) {
            guard !finished else { return }
            finished = true
            parent.timer.commitEdit(parent.unit, text: field.stringValue)
            let all = TimerController.Unit.allCases
            if next, let i = all.firstIndex(of: parent.unit), i + 1 < all.count {
                parent.timer.beginEditing(all[i + 1])
            } else {
                parent.timer.endEditing()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.alignment = .center
        f.textColor = .white
        f.font = NSFont.monospacedDigitSystemFont(ofSize: 21, weight: .semibold)
        f.placeholderAttributedString = NSAttributedString(
            string: String(format: "%02d", timer.draft[unit.rawValue]),
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.3),
                         .font: NSFont.monospacedDigitSystemFont(ofSize: 21, weight: .semibold)])
        f.delegate = context.coordinator
        let coordinator = context.coordinator
        timer.commitActiveField = { [weak f, weak timer] emptyAsZero in
            // 칸이 이미 사라졌으면 입력 상태만 끝낸다
            guard let f else { timer?.endEditing(); return }
            coordinator.commitFromOutside(f, emptyAsZero: emptyAsZero)
        }
        DispatchQueue.main.async {
            f.window?.makeKey()
            f.window?.makeFirstResponder(f)
        }
        return f
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
    }
}

struct PlaceholderPage: View {
    var option: HomeOption
    var note: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.white.opacity(0.08))
                Image(systemName: option.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 46, height: 46)
            Text(option.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(note)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }
}
