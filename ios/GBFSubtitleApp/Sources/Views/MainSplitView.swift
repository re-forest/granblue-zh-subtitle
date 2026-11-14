import SwiftUI

/// 主畫面佈局：頂部極簡控制列 ＋ 上方 78% 遊戲 WKWebView ＋ 下方 22% 固定雙語字幕艙
struct MainSplitView: View {
    @ObservedObject var sessionManager: SubtitleSessionManager

    @State private var showingHistory = false
    @State private var showingSettings = false

    private let abyssColor = Color(red: 7 / 255, green: 21 / 255, blue: 25 / 255)
    private let brassColor = Color(red: 212 / 255, green: 180 / 255, blue: 117 / 255)
    private let crystalColor = Color(red: 110 / 255, green: 231 / 255, blue: 216 / 255)
    private let ivoryColor = Color(red: 247 / 255, green: 244 / 255, blue: 235 / 255)

    var body: some View {
        VStack(spacing: 0) {
            topControlBar

            GeometryReader { geometry in
                let isLandscape = geometry.size.width > geometry.size.height
                let minDeckHeight: CGFloat = isLandscape ? 116 : 156
                let targetDeckRatio: CGFloat = isLandscape ? 0.28 : 0.22
                let deckHeight = max(minDeckHeight, min(geometry.size.height * 0.42, geometry.size.height * targetDeckRatio))
                let gameHeight = max(120, geometry.size.height - deckHeight)

                VStack(spacing: 0) {
                    GBFWebView(sessionManager: sessionManager)
                        .frame(height: gameHeight)
                        .clipped()

                    SubtitleDeckView(
                        sessionManager: sessionManager,
                        onOpenHistory: { showingHistory = true },
                        onOpenSettings: { showingSettings = true }
                    )
                    .frame(height: deckHeight)
                }
            }
        }
        .background(abyssColor.ignoresSafeArea())
        .sheet(isPresented: $showingHistory) {
            HistoryDrawerView(sessionManager: sessionManager)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheetView(sessionManager: sessionManager)
        }
        .sheet(item: $sessionManager.popupWebViewConfiguration) { popup in
            NavigationStack {
                PopupWebViewContainer(webView: popup.webView)
                    .navigationTitle("帳號登入驗證")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("關閉") {
                                sessionManager.popupWebViewConfiguration = nil
                            }
                        }
                    }
            }
        }
    }

    private var topControlBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Button {
                    sessionManager.goBackWebPage()
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 32, height: 32)
                }
                .disabled(!sessionManager.canGoBack)
                .opacity(sessionManager.canGoBack ? 1 : 0.35)
                .accessibilityLabel("上一頁")

                Button {
                    sessionManager.reloadWebPage()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("重新載入遊戲")

                Button {
                    sessionManager.navigateHome()
                } label: {
                    Image(systemName: "house")
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("回到碧藍幻想首頁")
            }

            Spacer()

            Button {
                sessionManager.toggleTranslationEnabled()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: sessionManager.isTranslationEnabled ? "captions.bubble.fill" : "captions.bubble")
                    Text(sessionManager.isTranslationEnabled ? "翻譯開啟" : "已暫停")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(
                        sessionManager.isTranslationEnabled
                            ? crystalColor.opacity(0.16)
                            : Color.white.opacity(0.08)
                    )
                )
                .overlay(
                    Capsule().stroke(
                        sessionManager.isTranslationEnabled ? crystalColor.opacity(0.6) : brassColor.opacity(0.35),
                        lineWidth: 1
                    )
                )
                .foregroundStyle(sessionManager.isTranslationEnabled ? crystalColor : ivoryColor.opacity(0.75))
            }
            .accessibilityLabel("切換即時翻譯")

            Button {
                showingHistory = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle")
                    Text("\(sessionManager.historyEntries.count)/\(SubtitleSessionManager.maxHistoryCount)")
                        .font(.caption2.monospacedDigit())
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .overlay(Capsule().stroke(brassColor.opacity(0.4), lineWidth: 1))
                .foregroundStyle(ivoryColor)
            }
            .accessibilityLabel("台詞歷史紀錄")

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .frame(width: 32, height: 32)
                    .foregroundStyle(brassColor)
            }
            .accessibilityLabel("翻譯與顯示設定")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(ivoryColor)
        .background(abyssColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(brassColor.opacity(0.45))
                .frame(height: 1)
        }
    }
}
