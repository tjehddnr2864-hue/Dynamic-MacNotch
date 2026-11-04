import AppKit
import SwiftUI

/// 업데이트 내용 화면 (업데이트 완료 알림을 눌렀을 때). 릴리스 노트를 이 화면을 열 때만 가져오고, 닫으면 메모리에서 사라진다.
/// 메모리·자원 테스트 표는 보여 주지 않는다.
struct UpdateNotesPage: View {
    enum Line: Hashable {
        case heading(String)
        case bullet(String)
        case text(String)
    }

    private let linesState = State(initialValue: [Line]?.none)
    private let failedState = State(initialValue: false)
    private var lines: [Line]? {
        get { linesState.wrappedValue }
        nonmutating set { linesState.wrappedValue = newValue }
    }
    private var failed: Bool {
        get { failedState.wrappedValue }
        nonmutating set { failedState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 12, weight: .semibold)).foregroundStyle(.blue)
                Text(T("\(Updater.currentVersion) 업데이트 내용", "What's New in \(Updater.currentVersion)"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Button { NSWorkspace.shared.open(Updater.releasePageURL) } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(T("GitHub에서 보기", "View on GitHub"))
            }
            if let lines {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(lines, id: \.self) { row($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer(minLength: 0)
                Group {
                    if failed {
                        Text(T("업데이트 내용을 불러오지 못했습니다", "Couldn't load the update notes"))
                    } else {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 2)
        .onAppear {
            Updater.shared.fetchReleaseNotes { body in
                if let body { lines = Self.parse(body) } else { failed = true }
            }
        }
    }

    @ViewBuilder
    private func row(_ line: Line) -> some View {
        switch line {
        case .heading(let s):
            Text(Self.inline(s)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white).padding(.top, 3)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("•")
                Text(Self.inline(s)).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
        case .text(let s):
            Text(Self.inline(s)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }

    /// 릴리스 노트를 화면용 줄로. 메모리·자원 테스트 절과 자동 업데이트 안내 줄은 뺀다.
    /// 노트는 '영어 · 한국어' 형식이므로 앱 언어에 맞는 쪽만 고른다.
    static func parse(_ body: String) -> [Line] {
        var result: [Line] = []
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## Memory") || line.hasPrefix("## 메모리") { break }
            if line.isEmpty || line.hasPrefix("1.0.1+") { continue }
            if line.hasPrefix("## ") { result.append(.heading(localized(String(line.dropFirst(3))))) }
            else if line.hasPrefix("- ") { result.append(.bullet(localized(String(line.dropFirst(2))))) }
            else { result.append(.text(localized(line))) }
        }
        return result
    }

    private static func localized(_ s: String) -> String {
        let parts = s.components(separatedBy: " · ")
        guard parts.count > 1 else { return s }
        return (L10n.isEnglish ? parts.first : parts.last) ?? s
    }
}
