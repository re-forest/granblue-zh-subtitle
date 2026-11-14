import Foundation

/// 術語匹配項目
struct GlossaryPair: Equatable, Sendable {
    let jp: String
    let zh: String
}

/// 負責載入角色日繁譯名對照表、提取當句術語、組裝 PFML3 提示詞與匯出劇本格式
final class GlossaryMatcher: @unchecked Sendable {
    private let characterNames: [String: String]
    private let sortedGlossaryEntries: [GlossaryPair]

    init(characterNames: [String: String]) {
        self.characterNames = characterNames
        self.sortedGlossaryEntries = characterNames
            .filter { jp, zh in
                !jp.isEmpty && !zh.isEmpty && !Self.isQuestionMarksOnly(jp)
            }
            .map { GlossaryPair(jp: $0.key, zh: $0.value) }
            .sorted { lhs, rhs in
                if lhs.jp.count != rhs.jp.count {
                    return lhs.jp.count > rhs.jp.count
                }
                return lhs.jp < rhs.jp
            }
    }

    /// 從 App Bundle 載入預設的 `character-names.json`
    convenience init(bundle: Bundle = .main) {
        if let url = bundle.url(forResource: "character-names", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.init(characterNames: decoded)
        } else {
            self.init(characterNames: [:])
        }
    }

    private static func isQuestionMarksOnly(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0 == "？" || $0 == "?" }
    }

    /// 轉換說話者名稱（完整命中優先；未命中時去除結尾全半形括號註記後再查）
    func resolveSpeaker(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }
        if let direct = characterNames[name] {
            return direct
        }
        let base = name
            .replacingOccurrences(of: "[（(].*?[)）]$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return characterNames[base] ?? name
    }

    /// 長詞優先提取當句涉及的角色與專有名詞，並遮蔽已命中區段避免重複配對
    func extractGlossary(from text: String, maxCount: Int = 8) -> [GlossaryPair] {
        guard !text.isEmpty, !sortedGlossaryEntries.isEmpty else { return [] }
        var matched: [GlossaryPair] = []
        var remaining = text
        for entry in sortedGlossaryEntries {
            guard remaining.contains(entry.jp) else { continue }
            matched.append(entry)
            remaining = remaining.replacingOccurrences(of: entry.jp, with: "\u{0}")
            if matched.count >= maxCount {
                break
            }
        }
        return matched
    }

    /// 跳脫輸入文字中可能干擾 PLaMo 控制標籤的片段
    static func sanitizePlamoText(_ value: String) -> String {
        value.replacingOccurrences(of: "<|plamo:", with: "＜|plamo:")
    }

    /// 組裝 PLaMo 3 Translate 標準 PFML3 提示詞
    func buildPlamoPrompt(
        text: String,
        glossary: [GlossaryPair] = [],
        context: String = ""
    ) -> String {
        let safeText = Self.sanitizePlamoText(text)
        let safeContext = Self.sanitizePlamoText(context).trimmingCharacters(in: .whitespacesAndNewlines)

        var prompt = "<|plamo:tag|>dataset<|plamo:msg|>translation"
        if !safeContext.isEmpty {
            prompt += "<|plamo:tag|>context<|plamo:msg|>" + safeContext
        }
        if !glossary.isEmpty {
            prompt += "<|plamo:tag|>glossary"
            for pair in glossary {
                prompt += "<|plamo:index|>"
                    + Self.sanitizePlamoText(pair.jp)
                    + "<|plamo:item|>"
                    + Self.sanitizePlamoText(pair.zh)
            }
        }
        prompt += "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>"
            + safeText
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>zh-hant<|plamo:msg|>"
        return prompt
    }

    /// 格式化劇本歷史紀錄為繁中與原文雙語文字檔內容
    static func formatHistoryText(_ entries: [SubtitleHistoryEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        let blocks = entries.map { entry -> String in
            let timePrefix = entry.time.isEmpty ? "" : "[\(entry.time)] "
            let header = entry.speaker.isEmpty
                ? timePrefix.trimmingCharacters(in: .whitespaces)
                : "\(timePrefix)\(entry.speaker)"
            var lines: [String] = []
            if !header.isEmpty {
                lines.append(header)
            }
            lines.append("繁中：\(entry.zh)")
            if !entry.ja.isEmpty {
                lines.append("原文：\(entry.ja)")
            }
            return lines.joined(separator: "\n")
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// 產生含 UTF-8 BOM 的 `.txt` 匯出資料（確保 Windows 記事本等軟體開啟不亂碼）
    static func exportHistoryData(_ entries: [SubtitleHistoryEntry]) -> Data {
        var data = Data([0xEF, 0xBB, 0xBF])
        let body = formatHistoryText(entries)
        if let utf8 = body.data(using: .utf8) {
            data.append(utf8)
        }
        return data
    }
}
