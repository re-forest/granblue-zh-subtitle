import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 供原生 ShareLink 使用的 UTF-8 BOM .txt 劇本可傳輸型別
struct SubtitleTranscriptDocument: Transferable {
    let filename: String
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { item in
            item.data
        }
        .suggestedFileName { item in
            item.filename
        }
    }
}

/// 500 筆雙語台詞歷史紀錄抽屜與劇本匯出介面
struct HistoryDrawerView: View {
    @ObservedObject var sessionManager: SubtitleSessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirmation = false
    @State private var copiedNotice = false

    private let abyssColor = Color(red: 7 / 255, green: 21 / 255, blue: 25 / 255)
    private let brassColor = Color(red: 212 / 255, green: 180 / 255, blue: 117 / 255)
    private let crystalColor = Color(red: 110 / 255, green: 231 / 255, blue: 216 / 255)
    private let ivoryColor = Color(red: 247 / 255, green: 244 / 255, blue: 235 / 255)

    var body: some View {
        NavigationStack {
            Group {
                if sessionManager.historyEntries.isEmpty {
                    ContentUnavailableView(
                        "尚無翻譯歷史紀錄",
                        systemImage: "text.bubble",
                        description: Text("進入劇情對話後，譯文與原文會自動暫存於此（上限 \(SubtitleSessionManager.maxHistoryCount) 筆）。")
                    )
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(sessionManager.historyEntries) { entry in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(entry.speaker.isEmpty ? "旁白" : entry.speaker)
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(crystalColor)
                                        Spacer()
                                        Text(entry.time)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }

                                    Text(entry.zh)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(ivoryColor)
                                        .textSelection(.enabled)

                                    if !entry.ja.isEmpty {
                                        Text(entry.ja)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(Color(red: 12 / 255, green: 30 / 255, blue: 36 / 255))
                                .id(entry.id)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .onAppear {
                            if let lastID = sessionManager.historyEntries.last?.id {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .background(abyssColor)
            .navigationTitle("台詞紀錄 (\(sessionManager.historyEntries.count)/\(SubtitleSessionManager.maxHistoryCount))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !sessionManager.historyEntries.isEmpty {
                        Button {
                            let plain = GlossaryMatcher.formatHistoryText(sessionManager.historyEntries)
                            UIPasteboard.general.string = plain
                            copiedNotice = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copiedNotice = false
                            }
                        } label: {
                            Image(systemName: copiedNotice ? "checkmark" : "doc.on.doc")
                        }
                        .accessibilityLabel("複製全部紀錄文字")

                        let doc = SubtitleTranscriptDocument(
                            filename: sessionManager.generateExportFilename(),
                            data: sessionManager.generateExportTextData()
                        )
                        ShareLink(
                            item: doc,
                            preview: SharePreview(doc.filename, image: Image(systemName: "doc.text"))
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("匯出 UTF-8 劇本檔")

                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("清空紀錄")
                    }
                }
            }
            .confirmationDialog(
                "確定要清空全部 \(sessionManager.historyEntries.count) 筆台詞紀錄嗎？",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("清空紀錄", role: .destructive) {
                    sessionManager.clearHistory()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}
