import SwiftUI
import UniformTypeIdentifiers

/// 翻譯引擎、GGUF 模型管理、外部 API 與字幕顯示設定面板
struct SettingsSheetView: View {
    @ObservedObject var sessionManager: SubtitleSessionManager
    @ObservedObject var downloadManager: ModelDownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var draft: SubtitleSettings
    @State private var isTestingServer = false
    @State private var serverTestResultMessage: String?
    @State private var serverTestSucceeded = false
    @State private var showingFileImporter = false
    @State private var importErrorMessage: String?
    @State private var customFiles: [String] = []

    init(sessionManager: SubtitleSessionManager) {
        self.sessionManager = sessionManager
        self.downloadManager = sessionManager.downloadManager
        self._draft = State(initialValue: sessionManager.settings)
    }

    var body: some View {
        NavigationStack {
            Form {
                inferenceModeSection

                if draft.inferenceMode == .localMetal {
                    localModelSection
                } else {
                    externalServerSection
                }

                displayAndContextSection
            }
            .navigationTitle("翻譯與字幕設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("套用") {
                        sessionManager.applyUpdatedSettings(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                refreshCustomFiles()
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                handleImportResult(result)
            }
        }
    }

    private var inferenceModeSection: some View {
        Section("推論執行模式") {
            Picker("翻譯引擎", selection: $draft.inferenceMode) {
                ForEach(InferenceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if draft.inferenceMode == .localMetal {
                Text("使用 Apple Metal GPU 於裝置本機離線翻譯。遊戲翻頁時可於下一個 Token 邊界即時中斷舊句推論。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("連接電腦區域網路（Ollama、LM Studio、llama-server）或遠端相容端點，免下載本機權重。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var localModelSection: some View {
        Section("本機離線模型（GGUF）") {
            ForEach(LocalModelVariant.allCases) { variant in
                modelRow(for: variant)
            }

            if downloadManager.isDownloading, let progress = downloadManager.progress {
                VStack(alignment: .leading, spacing: 6) {
                    Text(progress.descriptionText)
                        .font(.caption)
                    if let percent = progress.percent {
                        ProgressView(value: Double(percent), total: 100)
                    } else {
                        ProgressView()
                    }
                    Button("取消下載", role: .destructive) {
                        downloadManager.cancelDownload()
                    }
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }

            if let errorText = downloadManager.lastError {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            customGGUFSubView
        }
    }

    private func modelRow(for variant: LocalModelVariant) -> some View {
        let isSelected = draft.customModelFilename.isEmpty && draft.modelVariant == variant
        let ready = downloadManager.isModelReady(variant)
        let sizeMB = downloadManager.installedSizeMB(for: variant.filename)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    draft.customModelFilename = ""
                    draft.modelVariant = variant
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? .teal : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(variant.displayName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(variant.summaryDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if ready {
                    Text(sizeMB.map { "\($0) MB" } ?? "已下載")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 12) {
                if !ready {
                    Button("立即下載") {
                        draft.customModelFilename = ""
                        draft.modelVariant = variant
                        Task {
                            _ = try? await downloadManager.downloadModel(variant)
                            refreshCustomFiles()
                        }
                    }
                    .font(.caption)
                    .disabled(downloadManager.isDownloading)
                } else {
                    Button("刪除模型檔", role: .destructive) {
                        downloadManager.deleteModel(filename: variant.filename)
                        refreshCustomFiles()
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var customGGUFSubView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("自備 GGUF 權重檔")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("從「檔案」匯入") {
                    showingFileImporter = true
                }
                .font(.caption)
            }

            if !customFiles.isEmpty {
                Picker("選用本機檔案", selection: $draft.customModelFilename) {
                    Text("使用上方官方下載項目").tag("")
                    ForEach(customFiles, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }

            if let importErrorMessage {
                Text(importErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var externalServerSection: some View {
        Section("外部 API 伺服器設定") {
            Picker("服務預設類型", selection: $draft.serverPreset) {
                ForEach(ServerPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .onChange(of: draft.serverPreset) { _, newPreset in
                if draft.serverEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || ServerPreset.allCases.map(\.defaultEndpoint).contains(draft.serverEndpoint) {
                    draft.serverEndpoint = newPreset.defaultEndpoint
                }
                draft.serverUsePlamo = (newPreset == .llamaPlamo)
            }

            TextField("API 端點網址（例：http://192.168.1.10:11434）", text: $draft.serverEndpoint)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("模型名稱（如 ollama 模型 ID，可留空）", text: $draft.serverModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("API Key（本機服務通常免填）", text: $draft.serverApiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if draft.serverPreset == .custom {
                Toggle("使用 PLaMo 原生 /v1/completions 格式", isOn: $draft.serverUsePlamo)
            }

            HStack {
                Button {
                    runServerTest()
                } label: {
                    if isTestingServer {
                        ProgressView()
                    } else {
                        Text("測試連線與試譯")
                    }
                }
                .disabled(isTestingServer)

                Spacer()
            }

            if let serverTestResultMessage {
                Text(serverTestResultMessage)
                    .font(.caption)
                    .foregroundStyle(serverTestSucceeded ? .green : .orange)
            }
        }
    }

    private var displayAndContextSection: some View {
        Section("字幕顯示與語境") {
            VStack(alignment: .leading) {
                HStack {
                    Text("字幕字級比例")
                    Spacer()
                    Text("\(Int(round(draft.fontScale * 100)))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $draft.fontScale, in: 0.7...1.4, step: 0.05)
            }

            Toggle("長句自動縮小字級避免裁切", isOn: $draft.autoFit)
            Toggle("劇情語境連貫（參考前 2 句台詞）", isOn: $draft.contextEnabled)
        }
    }

    private func refreshCustomFiles() {
        let builtInNames = Set(LocalModelVariant.allCases.map(\.filename))
        customFiles = downloadManager.availableCustomGGUFFilenames()
            .filter { !builtInNames.contains($0) }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        importErrorMessage = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let importedName = try downloadManager.importCustomModel(from: url)
                refreshCustomFiles()
                draft.customModelFilename = importedName
            } catch {
                importErrorMessage = "匯入失敗：\(error.localizedDescription)"
            }
        case .failure(let error):
            importErrorMessage = "選擇檔案失敗：\(error.localizedDescription)"
        }
    }

    private func runServerTest() {
        isTestingServer = true
        serverTestResultMessage = nil
        let config = draft.serverConfiguration
        Task {
            do {
                let outcome = try await sessionManager.externalEngine.testConnection(config)
                serverTestSucceeded = true
                serverTestResultMessage = "連線成功（\(outcome.latencyMs) ms）：\(outcome.sample)"
            } catch {
                serverTestSucceeded = false
                serverTestResultMessage = error.localizedDescription
            }
            isTestingServer = false
        }
    }
}
