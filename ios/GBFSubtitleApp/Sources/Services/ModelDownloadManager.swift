import Combine
import Foundation

/// 下載錯誤型別
enum ModelDownloadError: LocalizedError {
    case cancelled
    case httpError(statusCode: Int)
    case incompleteFile
    case fileMoveFailed(String)
    case networkFailure(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "已取消模型下載。"
        case .httpError(let statusCode):
            return "下載翻譯模型失敗（HTTP \(statusCode)），請稍後重試或改用外部 API 模式。"
        case .incompleteFile:
            return "下載的模型檔案大小異常或不完整，請刪除後重新下載。"
        case .fileMoveFailed(let reason):
            return "儲存模型檔案失敗：\(reason)"
        case .networkFailure(let reason):
            return "無法連線至 Hugging Face 下載模型：\(reason)"
        }
    }
}

/// 負責管理 Documents/models 內的 GGUF 模型檢查、串流下載、iCloud 備份排除與檔案匯入
@MainActor
final class ModelDownloadManager: NSObject, ObservableObject {
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: ModelDownloadProgress?
    @Published private(set) var lastError: String?

    private var downloadSession: URLSession?
    private var currentTask: URLSessionDownloadTask?
    private var activeVariant: LocalModelVariant?
    private var activeContinuation: CheckedContinuation<URL, Error>?
    private var lastProgressEmit: ContinuousClock.Instant = .now

    var modelsDirectoryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("models", isDirectory: true)
    }

    override init() {
        super.init()
        ensureModelsDirectoryExists()
    }

    func ensureModelsDirectoryExists() {
        let dir = modelsDirectoryURL
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var mutableDir = dir
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableDir.setResourceValues(resourceValues)
    }

    func fileURL(for variant: LocalModelVariant) -> URL {
        modelsDirectoryURL.appendingPathComponent(variant.filename, isDirectory: false)
    }

    func fileURL(forCustomFilename filename: String) -> URL? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return modelsDirectoryURL.appendingPathComponent(trimmed, isDirectory: false)
    }

    /// 檢查指定內建模型是否已存在且檔案大小符合完整性門檻
    func isModelReady(_ variant: LocalModelVariant) -> Bool {
        let url = fileURL(for: variant)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.int64Value >= variant.minimumValidBytes
    }

    /// 取得已存在於 Documents/models 的所有可用 GGUF 檔名
    func availableCustomGGUFFilenames() -> [String] {
        ensureModelsDirectoryExists()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: modelsDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// 取得指定模型目前磁碟佔用 MB 數
    func installedSizeMB(for filename: String) -> Int? {
        let url = modelsDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return Int(size.int64Value / 1_048_576)
    }

    /// 匯入使用者從「檔案」App 選擇的本機 .gguf 檔至 Documents/models
    func importCustomModel(from sourceURL: URL) throws -> String {
        ensureModelsDirectoryExists()
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let targetName = sourceURL.lastPathComponent
        let destination = modelsDirectoryURL.appendingPathComponent(targetName, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        excludeFromBackup(destination)
        return targetName
    }

    /// 刪除指定模型以釋放手機儲存空間
    func deleteModel(filename: String) {
        let target = modelsDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        try? FileManager.default.removeItem(at: target)
        let part = modelsDirectoryURL.appendingPathComponent("\(filename).part", isDirectory: false)
        try? FileManager.default.removeItem(at: part)
    }

    /// 確保指定的模型可立即載入；若尚未下載則自動從 Hugging Face 串流下載
    func ensureModel(
        variant: LocalModelVariant,
        customFilename: String = "",
        onProgress: (@MainActor (ModelDownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        let trimmedCustom = customFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty,
           let customURL = fileURL(forCustomFilename: trimmedCustom),
           FileManager.default.fileExists(atPath: customURL.path) {
            return customURL
        }

        if isModelReady(variant) {
            return fileURL(for: variant)
        }

        return try await downloadModel(variant, onProgress: onProgress)
    }

    /// 下載指定的官方量化模型（使用 URLSessionDownloadDelegate 寫入暫存檔後原子移動）
    func downloadModel(
        _ variant: LocalModelVariant,
        onProgress: (@MainActor (ModelDownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        if isDownloading {
            cancelDownload()
        }

        ensureModelsDirectoryExists()
        lastError = nil
        isDownloading = true
        activeVariant = variant
        let initial = ModelDownloadProgress(percent: 0, loadedMB: 0, totalMB: 0)
        progress = initial
        onProgress?(initial)

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60

        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        downloadSession = session

        return try await withCheckedThrowingContinuation { continuation in
            self.activeContinuation = continuation
            self.onProgressHook = onProgress
            let task = session.downloadTask(with: variant.downloadURL)
            self.currentTask = task
            task.resume()
        }
    }

    private var onProgressHook: (@MainActor (ModelDownloadProgress) -> Void)?

    func cancelDownload() {
        currentTask?.cancel()
        currentTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        activeVariant = nil
        isDownloading = false
        progress = nil
        onProgressHook = nil

        if let cont = activeContinuation {
            activeContinuation = nil
            cont.resume(throwing: ModelDownloadError.cancelled)
        }
    }

    private func excludeFromBackup(_ fileURL: URL) {
        var mutableURL = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    private func finishDownload(result: Result<URL, Error>) {
        isDownloading = false
        currentTask = nil
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        activeVariant = nil
        onProgressHook = nil

        if case .failure(let error) = result, (error as? ModelDownloadError)?.localizedDescription != ModelDownloadError.cancelled.localizedDescription {
            lastError = error.localizedDescription
        }
        if case .success = result {
            progress = nil
        }

        guard let cont = activeContinuation else { return }
        activeContinuation = nil
        cont.resume(with: result)
    }
}

extension ModelDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let loadedMB = Int(totalBytesWritten / 1_048_576)
        let totalMB = totalBytesExpectedToWrite > 0 ? Int(totalBytesExpectedToWrite / 1_048_576) : 0
        let percent: Int? = totalBytesExpectedToWrite > 0
            ? min(99, Int((Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100.0))
            : nil
        let snapshot = ModelDownloadProgress(percent: percent, loadedMB: loadedMB, totalMB: totalMB)

        Task { @MainActor [weak self] in
            guard let self, self.currentTask === downloadTask else { return }
            let now = ContinuousClock.now
            if percent != 0 && self.lastProgressEmit.duration(to: now) < .milliseconds(250) {
                return
            }
            self.lastProgressEmit = now
            self.progress = snapshot
            self.onProgressHook?(snapshot)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 必須在此同步回呼返回前將系統暫存檔移走，否則系統會在返回後立即刪除 location
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelsDir = docs.appendingPathComponent("models", isDirectory: true)
        let tempStaging = modelsDir.appendingPathComponent("staging-\(UUID().uuidString).part", isDirectory: false)

        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            Task { @MainActor [weak self] in
                self?.finishDownload(result: .failure(ModelDownloadError.httpError(statusCode: httpResponse.statusCode)))
            }
            return
        }

        do {
            try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: tempStaging.path) {
                try fm.removeItem(at: tempStaging)
            }
            try fm.moveItem(at: location, to: tempStaging)
        } catch {
            Task { @MainActor [weak self] in
                self?.finishDownload(result: .failure(ModelDownloadError.fileMoveFailed(error.localizedDescription)))
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                try? FileManager.default.removeItem(at: tempStaging)
                return
            }
            guard let variant = self.activeVariant else {
                try? FileManager.default.removeItem(at: tempStaging)
                self.finishDownload(result: .failure(ModelDownloadError.cancelled))
                return
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: tempStaging.path)
            let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            guard fileSize >= variant.minimumValidBytes else {
                try? FileManager.default.removeItem(at: tempStaging)
                self.finishDownload(result: .failure(ModelDownloadError.incompleteFile))
                return
            }

            let finalURL = self.fileURL(for: variant)
            do {
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: tempStaging, to: finalURL)
                self.excludeFromBackup(finalURL)
                self.finishDownload(result: .success(finalURL))
            } catch {
                try? FileManager.default.removeItem(at: tempStaging)
                self.finishDownload(result: .failure(ModelDownloadError.fileMoveFailed(error.localizedDescription)))
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            Task { @MainActor [weak self] in
                self?.finishDownload(result: .failure(ModelDownloadError.cancelled))
            }
            return
        }
        Task { @MainActor [weak self] in
            self?.finishDownload(result: .failure(ModelDownloadError.networkFailure(error.localizedDescription)))
        }
    }
}
