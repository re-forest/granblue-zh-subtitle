import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(llama)
import llama
#endif

/// 執行緒安全的搶佔式中斷旗標，用於在數毫秒內通知底層推論迴圈中止
final class AtomicCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

/// 翻譯推論引擎錯誤訊息
enum TranslationError: LocalizedError {
    case modelNotAvailable(String)
    case modelLoadFailed(String)
    case promptTooLong
    case decodeFailed
    case invalidEndpoint(String)
    case serverTimeout
    case serverUnreachable
    case serverHTTPError(Int, String)
    case serverResponseTooLong
    case emptyTranslation

    var errorDescription: String? {
        switch self {
        case .modelNotAvailable(let detail):
            return detail
        case .modelLoadFailed(let detail):
            return "無法載入本機翻譯模型：\(detail)"
        case .promptTooLong:
            return "台詞或前後文語境超出模型上下文長度上限。"
        case .decodeFailed:
            return "推論解碼失敗，請重試或重新開啟翻譯引擎。"
        case .invalidEndpoint(let message):
            return message
        case .serverTimeout:
            return "LLM Server 回應逾時，請確認伺服器狀態。"
        case .serverUnreachable:
            return "無法連線至 LLM Server，請確認服務已啟動且網址與區網權限正確。"
        case .serverHTTPError(let code, let snippet):
            return snippet.isEmpty
                ? "LLM Server 回傳錯誤 (\(code))"
                : "LLM Server 回傳錯誤 (\(code))：\(snippet)"
        case .serverResponseTooLong:
            return "LLM Server 回應超出長度上限。"
        case .emptyTranslation:
            return "沒有收到繁中譯文，請重試。"
        }
    }
}

/// 本機離線推論引擎（使用 llama.cpp Apple Metal GPU 加速並支援 Token 串流與即時中斷）
final class LocalLlamaEngine: @unchecked Sendable {
    private let workerQueue = DispatchQueue(label: "com.granblue.zhsubtitle.local-llama", qos: .userInitiated)
    private let matcher: GlossaryMatcher
    private var loadedModelPath: String?

    #if canImport(llama)
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var backendInitialized = false
    #endif

    private var memoryWarningObserver: NSObjectProtocol?

    init(matcher: GlossaryMatcher) {
        self.matcher = matcher
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.unloadAsync()
        }
        #endif
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #if canImport(llama)
        let capturedContext = context
        let capturedModel = model
        let wasInit = backendInitialized
        workerQueue.async {
            if let capturedContext { llama_free(capturedContext) }
            if let capturedModel { llama_model_free(capturedModel) }
            if wasInit { llama_backend_free() }
        }
        #endif
    }

    var isNativeLlamaAvailable: Bool {
        #if canImport(llama)
        return true
        #else
        return false
        #endif
    }

    func unloadAsync() {
        workerQueue.async { [weak self] in
            self?.unloadLocked()
        }
    }

    func unload() async {
        await withCheckedContinuation { continuation in
            workerQueue.async { [weak self] in
                self?.unloadLocked()
                continuation.resume()
            }
        }
    }

    private func unloadLocked() {
        #if canImport(llama)
        if let context {
            llama_free(context)
            self.context = nil
        }
        if let model {
            llama_model_free(model)
            self.model = nil
        }
        vocab = nil
        #endif
        loadedModelPath = nil
    }

    func loadModelIfNeeded(at modelURL: URL) async throws {
        let path = modelURL.path
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try self.ensureLoadedLocked(path: path)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func translate(
        text: String,
        glossary: [GlossaryPair],
        context contextText: String,
        modelURL: URL,
        cancelFlag: AtomicCancelFlag,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let prompt = matcher.buildPlamoPrompt(text: text, glossary: glossary, context: contextText)
        let modelPath = modelURL.path

        #if canImport(llama)
        return try await withCheckedThrowingContinuation { continuation in
            workerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if cancelFlag.isCancelled || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try self.ensureLoadedLocked(path: modelPath)
                    let output = try self.runStreamingInferenceLocked(
                        prompt: prompt,
                        cancelFlag: cancelFlag,
                        onPartial: onPartial
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        #else
        // 當未連結 llama.xcframework 時（例如僅先打開 Swift 專案預覽 UI），嘗試連往本機 loopback PLaMo 伺服器作為備援
        let fallbackConfig = ServerConfiguration(
            preset: .llamaPlamo,
            endpoint: "http://127.0.0.1:8080",
            model: "",
            apiKey: "",
            usePlamoFormat: true
        )
        let apiEngine = ExternalAPIEngine(matcher: matcher)
        do {
            return try await apiEngine.translate(
                text: text,
                glossary: glossary,
                context: contextText,
                speaker: "",
                config: fallbackConfig
            )
        } catch {
            throw TranslationError.modelNotAvailable(
                "尚未連結 llama.xcframework（請使用 GitHub Actions 打包或執行 fetch-llama-xcframework.sh），且本機 127.0.0.1:8080 無回應。"
            )
        }
        #endif
    }

    #if canImport(llama)
    private func ensureLoadedLocked(path: String) throws {
        if loadedModelPath == path, model != nil, context != nil, vocab != nil {
            return
        }

        unloadLocked()

        guard FileManager.default.fileExists(atPath: path) else {
            throw TranslationError.modelNotAvailable("找不到 GGUF 模型檔案，請先下載模型。")
        }

        if !backendInitialized {
            llama_backend_init()
            backendInitialized = true
        }

        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = 99
        #endif

        guard let newModel = llama_model_load_from_file(path, modelParams) else {
            throw TranslationError.modelLoadFailed("無法開啟或解析 GGUF 權重檔。")
        }

        let newVocab = llama_model_get_vocab(newModel)
        let threads = Int32(max(2, min(6, ProcessInfo.processInfo.processorCount - 2)))

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 2048
        ctxParams.n_batch = 512
        ctxParams.n_threads = threads
        ctxParams.n_threads_batch = threads

        guard let newContext = llama_init_from_model(newModel, ctxParams) else {
            llama_model_free(newModel)
            throw TranslationError.modelLoadFailed("無法配置推論上下文記憶體（KV Cache）。")
        }

        self.model = newModel
        self.vocab = newVocab
        self.context = newContext
        self.loadedModelPath = path
    }

    private func runStreamingInferenceLocked(
        prompt: String,
        cancelFlag: AtomicCancelFlag,
        onPartial: @escaping @Sendable (String) -> Void
    ) throws -> String {
        guard let context, let vocab else {
            throw TranslationError.modelLoadFailed("翻譯模型尚未完成初始化。")
        }

        let promptTokens = tokenizeLocked(vocab: vocab, text: prompt)
        let nCtx = Int(llama_n_ctx(context))
        let maxGenerateTokens = 384
        if promptTokens.isEmpty || promptTokens.count >= nCtx - 16 {
            throw TranslationError.promptTooLong
        }

        llama_kv_self_clear(context)

        let batchCapacity: Int32 = 512
        var batch = llama_batch_init(batchCapacity, 0, 1)
        defer { llama_batch_free(batch) }

        // 依 n_batch 分批送入提示詞 Token
        var pos: Int32 = 0
        var offset = 0
        var lastLogitIndex: Int32 = 0
        while offset < promptTokens.count {
            if cancelFlag.isCancelled {
                throw CancellationError()
            }
            let chunkEnd = min(offset + Int(batchCapacity), promptTokens.count)
            batch.n_tokens = 0
            for idx in offset..<chunkEnd {
                let isLastTokenOfPrompt = (idx == promptTokens.count - 1)
                addTokenToBatch(&batch, token: promptTokens[idx], pos: pos, logits: isLastTokenOfPrompt)
                pos += 1
            }
            lastLogitIndex = batch.n_tokens - 1
            if llama_decode(context, batch) != 0 {
                throw TranslationError.decodeFailed
            }
            offset = chunkEnd
        }

        let samplerParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(samplerParams) else {
            throw TranslationError.decodeFailed
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        let stopMarkers = ["<|plamo:tag|>", "<|plamo:bos|>", "<|plamo:eos|>", "<|eos|>"]
        var pendingBytes: [CChar] = []
        var accumulated = ""
        var lastPublished = ""
        let tokenLimit = min(maxGenerateTokens, nCtx - promptTokens.count - 1)

        for _ in 0..<tokenLimit {
            if cancelFlag.isCancelled {
                throw CancellationError()
            }

            let nextToken = llama_sampler_sample(sampler, context, lastLogitIndex)
            if llama_vocab_is_eog(vocab, nextToken) {
                break
            }

            let pieceBytes = tokenToPieceLocked(vocab: vocab, token: nextToken)
            pendingBytes.append(contentsOf: pieceBytes)

            if let validPiece = flushValidUTF8(&pendingBytes) {
                accumulated += validPiece

                if let matchedRange = findEarliestStopMarker(in: accumulated, markers: stopMarkers) {
                    accumulated = String(accumulated[..<matchedRange.lowerBound])
                    break
                }

                let safeDisplay = trimTrailingPartialMarker(accumulated, markers: stopMarkers)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !safeDisplay.isEmpty && safeDisplay != lastPublished {
                    lastPublished = safeDisplay
                    onPartial(safeDisplay)
                }
            }

            batch.n_tokens = 0
            addTokenToBatch(&batch, token: nextToken, pos: pos, logits: true)
            pos += 1
            lastLogitIndex = 0

            if llama_decode(context, batch) != 0 {
                throw TranslationError.decodeFailed
            }
        }

        if cancelFlag.isCancelled {
            throw CancellationError()
        }

        if !pendingBytes.isEmpty, let tail = String(validatingUTF8: pendingBytes + [0]) {
            accumulated += tail
        }

        if let matchedRange = findEarliestStopMarker(in: accumulated, markers: stopMarkers) {
            accumulated = String(accumulated[..<matchedRange.lowerBound])
        }

        let finalResult = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalResult.isEmpty else {
            throw TranslationError.emptyTranslation
        }
        return finalResult
    }

    private func addTokenToBatch(_ batch: inout llama_batch, token: llama_token, pos: llama_pos, logits: Bool) {
        let index = Int(batch.n_tokens)
        batch.token[index] = token
        batch.pos[index] = pos
        batch.n_seq_id[index] = 1
        batch.seq_id[index]![0] = 0
        batch.logits[index] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    private func tokenizeLocked(vocab: OpaquePointer, text: String) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        let textByteCount = max(0, utf8.count - 1)
        var capacity = textByteCount + 16
        var buffer = [llama_token](repeating: 0, count: capacity)

        var count = utf8.withUnsafeBufferPointer { ptr in
            llama_tokenize(vocab, ptr.baseAddress, Int32(textByteCount), &buffer, Int32(capacity), true, true)
        }
        if count < 0 {
            capacity = Int(-count) + 4
            buffer = [llama_token](repeating: 0, count: capacity)
            count = utf8.withUnsafeBufferPointer { ptr in
                llama_tokenize(vocab, ptr.baseAddress, Int32(textByteCount), &buffer, Int32(capacity), true, true)
            }
        }
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    private func tokenToPieceLocked(vocab: OpaquePointer, token: llama_token) -> [CChar] {
        var smallBuf = [CChar](repeating: 0, count: 16)
        let written = smallBuf.withUnsafeMutableBufferPointer { ptr in
            llama_token_to_piece(vocab, token, ptr.baseAddress, Int32(ptr.count), 0, true)
        }
        if written >= 0 {
            return Array(smallBuf.prefix(Int(written)))
        }
        let needed = Int(-written)
        var largeBuf = [CChar](repeating: 0, count: needed)
        let retryWritten = largeBuf.withUnsafeMutableBufferPointer { ptr in
            llama_token_to_piece(vocab, token, ptr.baseAddress, Int32(ptr.count), 0, true)
        }
        guard retryWritten > 0 else { return [] }
        return Array(largeBuf.prefix(Int(retryWritten)))
    }

    private func flushValidUTF8(_ pending: inout [CChar]) -> String? {
        guard !pending.isEmpty else { return nil }
        if let str = String(validatingUTF8: pending + [0]) {
            pending.removeAll(keepingCapacity: true)
            return str
        }
        return nil
    }
    #endif

    /// 在字串中尋找最早出現的停止控制標籤範圍
    func findEarliestStopMarker(in text: String, markers: [String]) -> Range<String.Index>? {
        var earliest: Range<String.Index>?
        for marker in markers {
            if let range = text.range(of: marker) {
                if earliest == nil || range.lowerBound < earliest!.lowerBound {
                    earliest = range
                }
            }
        }
        return earliest
    }

    /// 避免於逐字串流期間暫時閃現尚未組完的 `<|plamo:...` 控制標籤前綴
    func trimTrailingPartialMarker(_ text: String, markers: [String]) -> String {
        for marker in markers {
            let maxCheck = min(text.count, marker.count - 1)
            if maxCheck <= 0 { continue }
            for len in stride(from: maxCheck, through: 1, by: -1) {
                let prefix = String(marker.prefix(len))
                if text.hasSuffix(prefix) {
                    return String(text.dropLast(len))
                }
            }
        }
        return text
    }
}

/// 外部相容 API 推論引擎（支援 Ollama、LM Studio、llama-server PLaMo 與 OpenAI 相容端點）
final class ExternalAPIEngine: @unchecked Sendable {
    private let matcher: GlossaryMatcher
    private let session: URLSession

    init(matcher: GlossaryMatcher) {
        self.matcher = matcher
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    static func validateEndpoint(_ rawURL: String) throws -> URL {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranslationError.invalidEndpoint("請輸入 LLM Server 的 API 端點網址。")
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw TranslationError.invalidEndpoint("API 端點網址格式不正確（僅支援 http:// 或 https://）。")
        }
        return url
    }

    static func shouldUsePlamoFormat(_ config: ServerConfiguration) -> Bool {
        if config.preset == .llamaPlamo { return true }
        if config.preset == .custom && config.usePlamoFormat { return true }
        guard let url = URL(string: config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        let cleanPath = url.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return cleanPath.hasSuffix("/completions") && !cleanPath.hasSuffix("/chat/completions")
    }

    static func resolveEndpoint(_ rawURL: String, plamoFormat: Bool) throws -> URL {
        let parsed = try validateEndpoint(rawURL)
        guard var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else {
            throw TranslationError.invalidEndpoint("API 端點網址格式不正確。")
        }
        let cleanPath = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        if cleanPath.hasSuffix("/completions") || cleanPath.hasSuffix("/chat/completions") {
            return parsed
        }
        let suffix = plamoFormat ? "/completions" : "/chat/completions"
        components.path = cleanPath.hasSuffix("/v1") ? "\(cleanPath)\(suffix)" : "\(cleanPath)/v1\(suffix)"
        guard let finalURL = components.url else {
            throw TranslationError.invalidEndpoint("無法解析 API 端點路徑。")
        }
        return finalURL
    }

    func testConnection(_ config: ServerConfiguration) async throws -> (latencyMs: Int, sample: String) {
        let start = ContinuousClock.now
        let plamoFormat = Self.shouldUsePlamoFormat(config)
        var body: [String: Any]
        if plamoFormat {
            body = [
                "prompt": matcher.buildPlamoPrompt(text: "こんにちは"),
                "temperature": 0,
                "stop": ["<|plamo:tag|>", "<|plamo:bos|>"]
            ]
        } else {
            body = [
                "messages": [
                    ["role": "system", "content": "請將日文翻譯成簡短繁體中文。"],
                    ["role": "user", "content": "こんにちは"]
                ],
                "temperature": 0.1
            ]
        }
        let sample = try await requestCompletion(body: body, config: config, maxTokens: 24)
        let elapsed = start.duration(to: ContinuousClock.now)
        let ms = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        return (latencyMs: max(1, ms), sample: sample)
    }

    func translate(
        text: String,
        glossary: [GlossaryPair],
        context: String,
        speaker: String,
        config: ServerConfiguration
    ) async throws -> String {
        if Self.shouldUsePlamoFormat(config) {
            let prompt = matcher.buildPlamoPrompt(text: text, glossary: glossary, context: context)
            let body: [String: Any] = [
                "prompt": prompt,
                "temperature": 0,
                "stop": ["<|plamo:tag|>", "<|plamo:bos|>"]
            ]
            return try await requestCompletion(body: body, config: config, maxTokens: 384)
        }

        var systemParts = [
            "你是《碧藍幻想》遊戲劇情的日文轉台灣繁體中文專業翻譯員。",
            "請只輸出自然流暢、符合角色語氣的繁體中文譯文，不要附加解釋、標題、引號或日文原文。"
        ]
        if !glossary.isEmpty {
            let terms = glossary.map { "\($0.jp) → \($0.zh)" }.joined(separator: "、")
            systemParts.append("專有名詞對照（請嚴格遵守）：\(terms)")
        }
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContext.isEmpty {
            systemParts.append("前句劇情語境（僅供語氣連貫參考，請勿重複翻譯）：\n\(trimmedContext)")
        }

        let userContent = speaker.isEmpty ? text : "說話者：\(speaker)\n\(text)"
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemParts.joined(separator: "\n\n")],
                ["role": "user", "content": userContent]
            ],
            "temperature": 0.1
        ]
        return try await requestCompletion(body: body, config: config, maxTokens: 384)
    }

    private func requestCompletion(
        body: [String: Any],
        config: ServerConfiguration,
        maxTokens: Int
    ) async throws -> String {
        let plamoFormat = Self.shouldUsePlamoFormat(config)
        let endpointURL = try Self.resolveEndpoint(config.endpoint, plamoFormat: plamoFormat)

        var payload = body
        payload["max_tokens"] = maxTokens
        payload["stream"] = false
        let trimmedModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            payload["model"] = trimmedModel
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            if urlError.code == .cancelled {
                throw CancellationError()
            }
            if urlError.code == .timedOut {
                throw TranslationError.serverTimeout
            }
            throw TranslationError.serverUnreachable
        } catch {
            throw TranslationError.serverUnreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.serverUnreachable
        }

        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let snippet = String(detail.prefix(80))
            throw TranslationError.serverHTTPError(http.statusCode, snippet)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.emptyTranslation
        }

        let choices = json["choices"] as? [[String: Any]]
        let firstChoice = choices?.first
        let messageContent = (firstChoice?["message"] as? [String: Any])?["content"] as? String
        let textContent = firstChoice?["text"] as? String
        let directContent = json["content"] as? String
        let finishReason = firstChoice?["finish_reason"] as? String

        let content = (messageContent ?? textContent ?? directContent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if finishReason == "length" && content.isEmpty {
            throw TranslationError.serverResponseTooLong
        }
        guard !content.isEmpty else {
            throw TranslationError.emptyTranslation
        }
        return content
    }
}
