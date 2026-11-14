import SwiftUI

/// 下方固定式雙語字幕艙，支援長句縮放、串流顯示與左滑展開歷史紀錄
struct SubtitleDeckView: View {
    @ObservedObject var sessionManager: SubtitleSessionManager
    let onOpenHistory: () -> Void
    let onOpenSettings: () -> Void

    private let abyssColor = Color(red: 7 / 255, green: 21 / 255, blue: 25 / 255)
    private let deckGradientTop = Color(red: 13 / 255, green: 34 / 255, blue: 40 / 255)
    private let brassColor = Color(red: 212 / 255, green: 180 / 255, blue: 117 / 255)
    private let crystalColor = Color(red: 110 / 255, green: 231 / 255, blue: 216 / 255)
    private let ivoryColor = Color(red: 247 / 255, green: 244 / 255, blue: 235 / 255)
    private let mutedTextColor = Color(red: 152 / 255, green: 180 / 255, blue: 183 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            Spacer(minLength: 2)

            captionArea

            if sessionManager.showOriginal && !sessionManager.originalText.isEmpty {
                Divider()
                    .overlay(brassColor.opacity(0.28))

                Text(sessionManager.originalText)
                    .font(.system(size: 12.5 * sessionManager.settings.fontScale))
                    .foregroundStyle(mutedTextColor)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 2)

            footerHintRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [deckGradientTop, abyssColor],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(brassColor)
                .frame(height: 1.5)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 36, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.width < -50 && abs(value.translation.height) < 60 {
                        onOpenHistory()
                    }
                }
        )
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            if !sessionManager.speaker.isEmpty {
                Text(sessionManager.speaker)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(crystalColor)
                    .lineLimit(1)
            } else {
                Text("旁白／系統")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mutedTextColor)
            }

            if sessionManager.isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .tint(crystalColor)
            }

            Spacer()

            Button(action: onOpenSettings) {
                Text(sessionManager.engineBadgeText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(brassColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(brassColor.opacity(0.12)))
                    .overlay(Capsule().stroke(brassColor.opacity(0.45), lineWidth: 1))
            }
        }
    }

    @ViewBuilder
    private var captionArea: some View {
        let baseFontSize = 18.0 * sessionManager.settings.fontScale
        if sessionManager.isError {
            HStack(spacing: 8) {
                Text(sessionManager.caption)
                    .font(.system(size: max(13, baseFontSize * 0.85), weight: .medium))
                    .foregroundStyle(Color.orange)
                    .lineLimit(3)
                Spacer()
                Button("重試") {
                    sessionManager.retryCurrentLine()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(brassColor)
                .foregroundStyle(abyssColor)
            }
        } else {
            Text(sessionManager.caption)
                .font(.system(size: baseFontSize, weight: .semibold))
                .foregroundStyle(ivoryColor)
                .lineLimit(sessionManager.settings.autoFit ? 4 : 6)
                .minimumScaleFactor(sessionManager.settings.autoFit ? 0.68 : 1.0)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerHintRow: some View {
        HStack {
            Button(action: onOpenHistory) {
                Label(
                    "← 左滑或點擊查看歷史紀錄 (\(sessionManager.historyEntries.count)/\(SubtitleSessionManager.maxHistoryCount))",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption2)
                .foregroundStyle(crystalColor.opacity(0.85))
            }
            Spacer()
        }
    }
}
