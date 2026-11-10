import AppKit
import Combine
import SwiftUI

/// 다운로드 확장 팝업 (음악 팝업과 같은 구성):
/// 1줄 브라우저 아이콘 · 파일명 · 브라우저/크기/속도 / 2줄 진행 바 · 퍼센트
struct DownloadPage: View {
    var activity: NotchActivity

    private var fraction: Double? {
        switch activity.detailValue ?? activity.value {
        case .ringPercent(let f), .ring(let f), .percent(let f), .bar(let f): return f
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Group {
                    if let art = activity.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "arrow.down.circle.fill").resizable().foregroundStyle(.blue)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(text: activity.title ?? T("다운로드", "Download"), font: .systemFont(ofSize: 14, weight: .semibold), color: .white)
                        .frame(height: 18)
                    Text(activity.subtitle ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                if let url = activity.fileURL {
                    // 다운로드 완료: 받은 위치를 Finder로 연다
                    Button {
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(url.deletingLastPathComponent())   // 옮겨졌거나 지워진 파일 → 폴더
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.blue)
                            Text(T("Finder에서 보기", "Show in Finder"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer(minLength: 0)
                            Text(url.deletingLastPathComponent().lastPathComponent)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.1), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else if let f = fraction {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.2))
                            Capsule().fill(Color.blue).frame(width: max(6, geo.size.width * min(1, f)))
                        }
                    }
                    .frame(height: 6)
                    Text("\(Int((f * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: 40, alignment: .trailing)
                } else {
                    SpinnerRing(tint: .blue).frame(width: 16, height: 16)
                    Text(T("진행률 확인 중", "Checking progress"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 0)
                }
            }
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.85), value: fraction)
        }
        .padding(.top, 4)
    }
}
