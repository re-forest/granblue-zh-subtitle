import Foundation
import SwiftUI

/// 統籌台詞擷取、快速翻頁搶佔中斷、近期 2 句語境維護與 500 筆歷史紀錄上限的會話管理員
@MainActor
final class SubtitleSessionManager: ObservableObject {
    static let maxHistoryCount = 500
    static let maxLineLength = 1000
    static let defaultGameURL = URL(string: "https://game.granbluefantasy.jp/")!

    @Published var settings: SubtitleSettings {
        didSet {
            settings.save()
        }
    }

    @Published private(set) var speaker: String = ""
    @Published private(set) var caption: String = "等待劇情台詞…"
    @Published private(set) var originalText: String = ""
    @Published private(set) var showOriginal: Bool = false
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var isError: Bool = false
    @Published private(set) var engineBadgeText: String = "準備中"
    @Published private(set) var isTranslationEnabled: Bool = true
    @Published private(set) var historyEntries: [SubtitleHistoryEntry] = []

    /// 供瀏覽器面板控制的狀態與事件
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var pageTitle: String = "Granblue Fantasy"
    @Published var currentPageURL: URL = SubtitleSessionManager.defaultGameURL
    @Published var popupWebViewConfiguration: IdentifiablePopupRequest?

    let downloadManager: ModelDownloadManager
    let matcher: GlossaryMatcher
    let localEngine: LocalLlamaEngine
    let externalEngine: ExternalAPIEngine

    private var currentLine = SubtitleLine(speaker: "", text: "")
    private var recentContext: [SubtitleLine] = []
    private var hasTranslatedOnce = false
    private var activeTask: Task<Void, Never>?
    private var activeCancelFlag: AtomicCancelFlag?
    private var generationCounter: UInt64 = 0
    private var bridgeForceCheckAction: (() -> Void)?
    private var webReloadAction: (() -> Void)?
    private var webBackAction: (() -> Void)?
    private var webHomeAction: (() -> Void)?

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    private static let exportStampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        return df
    }()

    init(
        downloadManager: ModelDownloadManager? = nil,
        matcher: GlossaryMatcher = GlossaryMatcher()
    ) {
        self.downloadManager = downloadManager ?? ModelDownloadManager()
        self.matcher = matcher
        self.localEngine = LocalLlamaEngine(matcher: matcher)
        self.externalEngine = ExternalAPIEngine(matcher: matcher)
        self.settings = SubtitleSettings.load()
        refreshEngineBadge()
    }

    func registerWebActions(
        reload: @escaping () -> Void,
        goBack: @escaping () -> Void,
        goHome: @escaping () -> Void,
        forceCheck: @escaping () -> Void
    ) {
        self.webReloadAction = reload
        self.webBackAction = goBack
        self.webHomeAction = goHome
        self.bridgeForceCheckAction = forceCheck
    }

    func reloadWebPage() { webReloadAction?() }
    func goBackWebPage() { webBackAction?() }
    func navigateHome() { webHomeAction?() }

    func refreshEngineBadge() {
        switch settings.inferenceMode {
        case .localMetal:
            if downloadManager.isDownloading {
                engineBadgeText = "模型下載中"
            } else if !settings.customModelFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engineBadgeText = "Metal · 自訂 GGUF"
            } else {
                engineBadgeText = "Metal · \(settings.modelVariant.shortBadgeTitle)"
            }
        case .externalAPI:
            engineBadgeText = "API · \(settings.serverPreset.displayName)"
        }
    }

    /// 處理來自 WKScriptMessageHandler 的橋接訊息
    func handleBridgePayload(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String else {
            return
        }
        switch type {
        case "subtitle-source-ready":
            if currentLine.isEmpty && !isBusy {
                caption = "已連線劇情畫面，等待台詞…"
            }
        case "subtitle-line":
            let rawSpeaker = (dict["speaker"] as? String) ?? ""
            let rawText = (dict["text"] as? String) ?? ""
            ingestExternalDialogue(speaker: rawSpeaker, text: rawText)
        default:
            break
        }
    }

    /// 統一台詞接收入口（供主力 WKWebView 與未來擴充介面共用）
    func ingestExternalDialogue(speaker rawSpeaker: String, text rawText: String) {
        let normalized = SubtitleLine(
            speaker: rawSpeaker.trimmingCharacters(in: .whitespacesAndNewlines),
            text: rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard normalized != currentLine else { return }
        currentLine = normalized
        guard isTranslationEnabled else {
            speaker = matcher.resolveSpeaker(normalized.speaker)
            originalText = normalized.text
            return
        }
        scheduleTranslation(for: normalized)
    }

    func toggleTranslationEnabled() {
        isTranslationEnabled.toggle()
        if !isTranslationEnabled {
            cancelActiveTranslation()
            isBusy = false
            isError = false
            caption = "已暫停即時翻譯"
            showOriginal = !currentLine.isEmpty
        } else {
            bridgeForceCheckAction?()
            if !currentLine.isEmpty {
                scheduleTranslation(for: currentLine)
            } else {
                caption = "等待劇情台詞…"
            }
        }
    }

    func retryCurrentLine() {
        isError = false
        if currentLine.isEmpty {
            caption = "等待劇情台詞…"
            bridgeForceCheckAction?()
        } else {
            scheduleTranslation(for: currentLine)
        }
    }

    func applyUpdatedSettings(_ nextSettings: SubtitleSettings) {
        let modeChanged = nextSettings.inferenceMode != settings.inferenceMode
        let modelChanged = nextSettings.modelVariant != settings.modelVariant
            || nextSettings.customModelFilename != settings.customModelFilename

        settings = nextSettings
        refreshEngineBadge()

        if modeChanged && nextSettings.inferenceMode == .externalAPI {
            downloadManager.cancelDownload()
            Task { await localEngine.unload() }
        } else if modelChanged {
            Task { await localEngine.unload() }
        }

        if (modeChanged || modelChanged) && !currentLine.isEmpty && isTranslationEnabled {
            hasTranslatedOnce = false
            scheduleTranslation(for: currentLine)
        }
    }

    func clearHistory() {
        historyEntries.removeAll()
    }

    func generateExportTextData() -> Data {
        GlossaryMatcher.exportHistoryData(historyEntries)
    }

    func generateExportFilename() -> String {
        "gbf-subtitles-\(Self.exportStampFormatter.string(from: Date())).txt"
    }

    func cancelActiveTranslation() {
        generationCounter &+= 1
        activeCancelFlag?.cancel()
        activeCancelFlag = nil
        activeTask?.cancel()
        activeTask = nil
    }

    private func scheduleTranslation(for line: SubtitleLine) {
        cancelActiveTranslation()
        isError = false

        let resolvedSpeaker = matcher.resolveSpeaker(line.speaker)
        speaker = resolvedSpeaker
        originalText = line.text

        guard !line.isEmpty else {
            isBusy = false
            showOriginal = false
            caption = "等待劇情台詞…"
            return
        }

        guard line.text.count <= Self.maxLineLength else {
            isBusy = false
            isError = true
            showOriginal = true
            caption = "這句台詞超出翻譯長度上限（\(Self.maxLineLength) 字）。"
            return
        }

        let currentGen = generationCounter
        let cancelFlag = AtomicCancelFlag()
        activeCancelFlag = cancelFlag

        isBusy = true
        if !hasTranslatedOnce {
            showOriginal = true
            caption = settings.inferenceMode == .localMetal ? "準備本機翻譯模型…" : "正在連線翻譯伺服器…"
        } else {
            showOriginal = false
            caption = "正在翻譯…"
        }

        let activeSettings = settings
        let glossary = matcher.extractGlossary(from: line.text)
        let contextPrompt = buildContextText(for: line.text, enabled: activeSettings.contextEnabled)

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: String
                switch activeSettings.inferenceMode {
                case .localMetal:
                    let modelURL = try await self.downloadManager.ensureModel(
                        variant: activeSettings.modelVariant,
                        customFilename: activeSettings.customModelFilename
                    ) { [weak self] progress in
                        guard let self, self.generationCounter == currentGen else { return }
                        self.caption = progress.descriptionText
                        self.showOriginal = true
                        self.refreshEngineBadge()
                    }
                    try Task.checkCancellation()
                    guard self.generationCounter == currentGen else { return }
                    self.refreshEngineBadge()
                    if !self.hasTranslatedOnce {
                        self.caption = "正在載入模型至 Metal GPU…"
                    }
                    result = try await self.localEngine.translate(
                        text: line.text,
                        glossary: glossary,
                        context: contextPrompt,
                        modelURL: modelURL,
                        cancelFlag: cancelFlag
                    ) { [weak self] partialText in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.generationCounter == currentGen,
                                  !cancelFlag.isCancelled else { return }
                            self.hasTranslatedOnce = true
                            self.showOriginal = true
                            self.caption = partialText
                        }
                    }

                case .externalAPI:
                    result = try await self.externalEngine.translate(
                        text: line.text,
                        glossary: glossary,
                        context: contextPrompt,
                        speaker: resolvedSpeaker,
                        config: activeSettings.serverConfiguration
                    )
                }

                try Task.checkCancellation()
                guard self.generationCounter == currentGen, !cancelFlag.isCancelled else { return }

                self.hasTranslatedOnce = true
                self.isBusy = false
                self.isError = false
                self.showOriginal = true
                self.caption = result
                self.appendContext(line)
                self.recordHistory(speaker: resolvedSpeaker, zh: result, ja: line.text)
            } catch is CancellationError {
                // 玩家快速翻頁切換新句，正常丟棄舊任務結果
            } catch {
                guard self.generationCounter == currentGen, !cancelFlag.isCancelled else { return }
                self.isBusy = false
                self.isError = true
                self.showOriginal = true
                self.caption = error.localizedDescription
            }
        }
    }

    private func buildContextText(for currentText: String, enabled: Bool) -> String {
        guard enabled, !recentContext.isEmpty else { return "" }
        return recentContext
            .filter { !$0.text.isEmpty && $0.text != currentText }
            .suffix(2)
            .map { $0.speaker.isEmpty ? $0.text : "\($0.speaker)：\($0.text)" }
            .joined(separator: "\n")
    }

    private func appendContext(_ line: SubtitleLine) {
        recentContext.removeAll { $0.text == line.text }
        recentContext.append(line)
        if recentContext.count > 2 {
            recentContext.removeFirst(recentContext.count - 2)
        }
    }

    private func recordHistory(speaker: String, zh: String, ja: String) {
        guard !ja.isEmpty, !zh.isEmpty else { return }
        if let last = historyEntries.last,
           last.speaker == speaker,
           last.ja == ja,
           last.zh == zh {
            return
        }
        let timestamp = Self.timeFormatter.string(from: Date())
        historyEntries.append(SubtitleHistoryEntry(time: timestamp, speaker: speaker, zh: zh, ja: ja))
        if historyEntries.count > Self.maxHistoryCount {
            historyEntries.removeFirst(historyEntries.count - Self.maxHistoryCount)
        }
    }
}
