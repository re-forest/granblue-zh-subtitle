import Foundation

/// 遊戲畫面上擷取到的單句台詞
struct SubtitleLine: Equatable, Sendable {
    var speaker: String
    var text: String

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 雙語歷史紀錄項目（記憶體最多保留 500 筆）
struct SubtitleHistoryEntry: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let time: String
    let speaker: String
    let zh: String
    let ja: String

    init(id: UUID = UUID(), time: String, speaker: String, zh: String, ja: String) {
        self.id = id
        self.time = time
        self.speaker = speaker
        self.zh = zh
        self.ja = ja
    }
}

/// 推論模式
enum InferenceMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case localMetal
    case externalAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localMetal:
            return "本機離線（Apple Metal）"
        case .externalAPI:
            return "外部 API 伺服器"
        }
    }
}

/// 官方提供且經過驗證的 GGUF 模型規格
enum LocalModelVariant: String, CaseIterable, Codable, Identifiable, Sendable {
    case plamo08b_q4km
    case plamo2b_q4km
    case plamo08b_q3km

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plamo08b_q4km:
            return "PLaMo 0.8B Q4_K_M（預設 · 約 547 MB）"
        case .plamo2b_q4km:
            return "PLaMo 2B Q4_K_M（高精準 · 約 1.68 GB）"
        case .plamo08b_q3km:
            return "PLaMo 0.8B Q3_K_M（輕量 · 約 464 MB）"
        }
    }

    var shortBadgeTitle: String {
        switch self {
        case .plamo08b_q4km:
            return "0.8B · Q4_K_M"
        case .plamo2b_q4km:
            return "2B · Q4_K_M"
        case .plamo08b_q3km:
            return "0.8B · Q3_K_M"
        }
    }

    var filename: String {
        switch self {
        case .plamo08b_q4km:
            return "plamo-3-translate-0.8b-Q4_K_M.gguf"
        case .plamo2b_q4km:
            return "plamo-3-translate-2b-Q4_K_M.gguf"
        case .plamo08b_q3km:
            return "plamo-3-translate-0.8b-Q3_K_M.gguf"
        }
    }

    var downloadURL: URL {
        switch self {
        case .plamo08b_q4km:
            return URL(string: "https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF/resolve/main/plamo-3-translate-0.8b-Q4_K_M.gguf")!
        case .plamo2b_q4km:
            return URL(string: "https://huggingface.co/pfnet/plamo-3-translate-2b-GGUF/resolve/main/plamo-3-translate-2b-Q4_K_M.gguf")!
        case .plamo08b_q3km:
            return URL(string: "https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF/resolve/main/plamo-3-translate-0.8b-Q3_K_M.gguf")!
        }
    }

    /// 完整性檢查的最小位元組門檻（低於此值視為未完整下載）
    var minimumValidBytes: Int64 {
        switch self {
        case .plamo08b_q4km:
            return 500 * 1024 * 1024
        case .plamo2b_q4km:
            return 1_600 * 1024 * 1024
        case .plamo08b_q3km:
            return 440 * 1024 * 1024
        }
    }

    var summaryDescription: String {
        switch self {
        case .plamo08b_q4km:
            return "極速低耗電預設方案，A17 Pro 上可達即時串流速度，推薦多數玩家使用。"
        case .plamo2b_q4km:
            return "適合 iPhone 15 Pro Max（8 GB RAM），長句與複雜語氣翻譯更精細。"
        case .plamo08b_q3km:
            return "體積最小且載入迅速，適合裝置可用空間有限時選用。"
        }
    }
}

/// 外部相容 LLM Server 預設型態
enum ServerPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case ollama
    case lmstudio
    case llamaPlamo
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama:
            return "Ollama"
        case .lmstudio:
            return "LM Studio"
        case .llamaPlamo:
            return "llama-server (PLaMo)"
        case .custom:
            return "自訂 OpenAI 相容端點"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .ollama:
            return "http://127.0.0.1:11434"
        case .lmstudio:
            return "http://127.0.0.1:1234"
        case .llamaPlamo:
            return "http://127.0.0.1:8080"
        case .custom:
            return "http://127.0.0.1:11434"
        }
    }
}

/// 外部 API 連線參數
struct ServerConfiguration: Equatable, Codable, Sendable {
    var preset: ServerPreset = .ollama
    var endpoint: String = "http://127.0.0.1:11434"
    var model: String = ""
    var apiKey: String = ""
    var usePlamoFormat: Bool = false
}

/// 儲存於 UserDefaults 的使用者偏好設定
struct SubtitleSettings: Equatable, Codable, Sendable {
    var fontScale: Double = 1.0
    var autoFit: Bool = true
    var contextEnabled: Bool = true
    var inferenceMode: InferenceMode = .localMetal
    var modelVariant: LocalModelVariant = .plamo08b_q4km
    var customModelFilename: String = ""
    var serverPreset: ServerPreset = .ollama
    var serverEndpoint: String = "http://127.0.0.1:11434"
    var serverModel: String = ""
    var serverApiKey: String = ""
    var serverUsePlamo: Bool = false

    var serverConfiguration: ServerConfiguration {
        ServerConfiguration(
            preset: serverPreset,
            endpoint: serverEndpoint,
            model: serverModel,
            apiKey: serverApiKey,
            usePlamoFormat: serverUsePlamo
        )
    }

    static let storageKey = "com.granblue.zhsubtitle.settings.v1"

    static func load() -> SubtitleSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var decoded = try? JSONDecoder().decode(SubtitleSettings.self, from: data) else {
            return SubtitleSettings()
        }
        decoded.fontScale = min(1.4, max(0.7, decoded.fontScale))
        return decoded
    }

    func save() {
        var copy = self
        copy.fontScale = min(1.4, max(0.7, fontScale))
        if let encoded = try? JSONEncoder().encode(copy) {
            UserDefaults.standard.set(encoded, forKey: Self.storageKey)
        }
    }
}

/// 下載進度回報結構
struct ModelDownloadProgress: Equatable, Sendable {
    var percent: Int?
    var loadedMB: Int
    var totalMB: Int

    var descriptionText: String {
        if let percent, totalMB > 0 {
            return "下載模型中（\(percent)% · \(loadedMB) / \(totalMB) MB）…"
        }
        return "下載模型中（\(loadedMB) MB）…"
    }
}
