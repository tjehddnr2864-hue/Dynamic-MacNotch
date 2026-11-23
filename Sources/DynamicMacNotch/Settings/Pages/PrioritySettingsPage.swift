import SwiftUI

/// 우선순위: 여러 상시 표시 항목 중 무엇을 먼저 보일지
struct PrioritySettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsForm {
            SettingsSection(T("상시 표시 우선순위", "Live Activity Priority"),
                            footer: T("여러 항목이 진행 중이면 위에 있는 항목이 보입니다.", "When several run at once, the higher one is shown."), more: T("여러 항목이 동시에 진행 중이면 위에 있는 항목이 노치에 표시됩니다. 노치 위에서 두 손가락으로 위로 쓸면 숨기고, 아래로 쓸면 다시 나타납니다.",
                                      "When several activities run at once, the one higher in the list is shown. Swipe up with two fingers on the notch to hide them, and swipe down to show them again.")) {
                ReorderList(items: settings.persistentOrder, onCommit: { settings.persistentOrder = $0 }) { key, index in
                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
                    Label(ActivityKind.liveName(key), systemImage: ActivityKind.liveSymbol(key))
                    Spacer()
                }
            }
        }
    }
}
