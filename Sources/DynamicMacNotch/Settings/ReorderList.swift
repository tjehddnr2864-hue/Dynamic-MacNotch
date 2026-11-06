import SwiftUI

/// 끌어서 순서를 바꾸는 목록. 왼쪽 손잡이(가로줄 3개)를 누른 채 위아래로 끌면 그 줄이 커서를 그대로 따라오고,
/// 다른 줄은 부드럽게 비켜 준다. 옆 줄과 충분히(줄 높이의 60%) 겹쳐야 자리가 바뀌어, 경계에서 흔들려도
/// 두 줄이 번갈아 바뀌며 햅틱이 계속 울리지 않는다. 자리가 바뀔 때마다 트랙패드 햅틱, 놓을 때 한 번만 저장.
struct ReorderList<Row: View>: View {
    var items: [String]
    var onCommit: ([String]) -> Void
    @ViewBuilder var row: (String, Int) -> Row

    private static var rowHeight: CGFloat { 34 }
    /// 자리를 바꾸려면 옆 줄과 이만큼(줄 높이 비율) 겹쳐야 한다
    private static var swapThreshold: CGFloat { 0.6 }
    private static var space: String { "reorderList" }

    private let draftState = State(initialValue: [String]?.none)
    private let draggingState = State(initialValue: String?.none)
    private let startState = State(initialValue: 0)
    private let dragYState = State(initialValue: CGFloat(0))
    private var draft: [String]? {
        get { draftState.wrappedValue }
        nonmutating set { draftState.wrappedValue = newValue }
    }
    private var dragging: String? {
        get { draggingState.wrappedValue }
        nonmutating set { draggingState.wrappedValue = newValue }
    }
    private var startIndex: Int {
        get { startState.wrappedValue }
        nonmutating set { startState.wrappedValue = newValue }
    }
    /// 누른 곳에서 커서가 움직인 거리 (목록 기준 좌표라 줄이 자리를 옮겨도 값이 튀지 않는다)
    private var dragY: CGFloat {
        get { dragYState.wrappedValue }
        nonmutating set { dragYState.wrappedValue = newValue }
    }

    var body: some View {
        let list = draft ?? items
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element) { index, key in
                let isDragged = dragging == key
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isDragged ? Color.accentColor : .secondary)
                        .frame(width: 24, height: Self.rowHeight)
                        .contentShape(Rectangle())
                        .onHover { inside in if dragging == nil { (inside ? NSCursor.openHand : NSCursor.arrow).set() } }
                        .gesture(dragGesture(key))
                        .help(T("끌어서 순서 바꾸기", "Drag to reorder"))
                    row(key, index)
                }
                .frame(height: Self.rowHeight)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isDragged ? Color.accentColor.opacity(0.14) : .clear)
                    .shadow(color: .black.opacity(isDragged ? 0.12 : 0), radius: 4, y: 2))
                .overlay(alignment: .bottom) {
                    if index < list.count - 1, !isDragged { Divider().opacity(dragging == nil ? 1 : 0.4) }
                }
                // 끄는 줄은 커서를 그대로 따라간다: 지금 칸에서 커서까지 남은 거리만큼
                .offset(y: isDragged ? dragY - CGFloat(index - startIndex) * Self.rowHeight : 0)
                .zIndex(isDragged ? 1 : 0)
            }
        }
        .coordinateSpace(name: Self.space)
    }

    private func dragGesture(_ key: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragging == nil {
                    dragging = key
                    draft = items
                    startIndex = items.firstIndex(of: key) ?? 0
                    NSCursor.closedHand.set()
                }
                // 목록 밖으로 너무 멀리 끌리지 않게
                let count = (draft ?? items).count
                let minY = -CGFloat(startIndex) * Self.rowHeight - 10
                let maxY = CGFloat(count - 1 - startIndex) * Self.rowHeight + 10
                dragY = min(max(value.translation.height, minY), maxY)

                guard var list = draft, var current = list.firstIndex(of: key) else { return }
                var moved = false
                // 지금 칸에서 커서까지의 거리가 기준을 넘을 때만 한 칸씩 (빠르게 끌면 여러 칸)
                while true {
                    let offset = dragY - CGFloat(current - startIndex) * Self.rowHeight
                    if offset > Self.rowHeight * Self.swapThreshold, current < list.count - 1 {
                        list.swapAt(current, current + 1)
                        current += 1
                    } else if offset < -Self.rowHeight * Self.swapThreshold, current > 0 {
                        list.swapAt(current, current - 1)
                        current -= 1
                    } else {
                        break
                    }
                    moved = true
                }
                guard moved else { return }
                withAnimation(.snappy(duration: 0.2)) { draft = list }
                // 자리가 바뀔 때마다 트랙패드에 '딸깍'
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            .onEnded { _ in
                if let list = draft, list != items { onCommit(list) }
                NSCursor.arrow.set()
                // 놓으면 제자리로 내려앉는다
                withAnimation(.snappy(duration: 0.2)) {
                    dragging = nil
                    draft = nil
                    dragY = 0
                }
            }
    }
}
