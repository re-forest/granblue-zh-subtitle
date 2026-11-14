# 碧藍幻想繁中字幕

專為《碧藍幻想》（Granblue Fantasy）設計的繁體中文即時字幕 Chrome 擴充功能（Manifest V3）。  
以唯讀方式擷取遊戲畫面中的日文台詞，透過本機 **PLaMo 3 Translate 0.8B**（WebGPU / CPU）或自訂相容 API 即時翻譯為繁體中文，並提供置頂「懸浮字幕」與「側邊欄字幕」雙模式即時顯示。

---

## 功能特色

- **懸浮字幕（子母畫面置頂）**：將字幕繪製為置頂子母畫面視窗，可自由拖曳與縮放；遊戲跨頁切換或整頁重新載入時，視窗會維持開啟並自動接續最新台詞。
- **側邊欄字幕（Chrome Side Panel）**：於瀏覽器右側開啟雙語對照側邊欄，上方固定顯示當前繁中譯文與日文原文，下方保留近期 25 筆劇情回顧。
- **劇情語境連貫與角色譯名對照**：
  - 支援「劇情語境連貫」開關，翻譯時自動參考前句對話上下文。
  - 內建《碧藍幻想》角色日繁譯名對照表（`extension/data/character-names.json`），維持角色名稱翻譯一致。
- **彈性推論引擎切換**：支援「自動 / GPU / CPU / API」四種模式；若本機 WebGPU 不可用會自動切換為 CPU 並於介面提示；選擇 **API** 可連接本機 Ollama、LM Studio、llama.cpp 或遠端 OpenAI 相容伺服器。
- **開箱即用的模型快取機制**：擴充功能已內建 `wllama` 推論環境；首次使用本機翻譯時會自動從 Hugging Face 下載模型並快取於瀏覽器本機空間（OPFS），免手動安裝步驟。
- **字級自適應與歷史紀錄匯出**：支援 70%–140% 字級調整與長句自動縮放；本機記憶體暫存最多 500 筆不重複台詞（關閉瀏覽器後清空），可一鍵匯出為 UTF-8 BOM `.txt` 劇本紀錄檔。

---

## 安裝與使用

1. 開啟 Chrome（建議版本 116 以上）前往 `chrome://extensions`。
2. 開啟右上角的「開發人員模式」。
3. 點擊「載入未封裝項目」，選擇本專案內的 `extension` 資料夾（或直接解壓發布壓縮檔並載入）。
4. 重新整理《碧藍幻想》遊戲分頁後，點擊工具列圖示即可開啟「懸浮字幕」或「側邊欄字幕」。
5. 首次開啟本機翻譯時，字幕視窗會顯示下載進度（約 547 MB）並自動快取至瀏覽器本機空間；若使用 **API 模式**則無需下載模型。

> **選用（完全離線預先配置）**：若希望把模型預先放入 `extension/model/` 而不透過瀏覽器首次下載，可執行 `powershell -ExecutionPolicy Bypass -File .\scripts\setup-runtime.ps1`。

---

## 打包與上架 Chrome 線上應用程式商店

執行以下腳本可驗證 `manifest.json`、圖示與必備檔案完整性，並於 `dist/` 產出壓縮檔：

```powershell
# 產出可直接上傳 Chrome 線上應用程式商店的套件（約 7.6 MB，首次執行自動下載並快取模型）
powershell -ExecutionPolicy Bypass -File .\scripts\build-release.ps1

# 產出包含 547 MB 離線模型的完整壓縮包（適合單機離線分發）
powershell -ExecutionPolicy Bypass -File .\scripts\build-release.ps1 -IncludeModel
```

---

## 專案結構

```text
.
├── extension/                  # Chrome 擴充功能本體
│   ├── manifest.json           # Manifest V3 設定與權限宣告
│   ├── background.js           # Service Worker 與狀態協調
│   ├── content.js              # 遊戲 DOM 唯讀擷取與重載防護
│   ├── engine.html / engine.js # 推論調度、OPFS 模型快取與語境組裝
│   ├── pip-renderer.js         # 子母畫面 Canvas 字幕繪製
│   ├── subtitles.js            # 字幕狀態、下載進度與雙模式同步
│   ├── popup.html / popup.js   # 工具列彈出控制面板
│   ├── sidepanel.html / .js    # 雙語對照側邊欄介面
│   ├── export-log.js           # 劇本格式 .txt 匯出
│   ├── data/                   # 角色日繁譯名對照表
│   ├── icons/                  # 擴充功能圖示（16 / 48 / 128 px）
│   ├── vendor/wllama/          # 內建 WebAssembly / WebGPU 推論執行環境
│   └── licenses/               # 第三方元件授權全文
├── docs/
│   └── architecture.html       # 系統架構說明
├── scripts/
│   ├── setup-runtime.ps1       # 選用：預先離線配置模型腳本
│   └── build-release.ps1       # 商店上架包與離線包驗證打包腳本
├── LICENSE                     # 本專案原始碼授權（MIT）
└── THIRD_PARTY_NOTICES.md      # 第三方推論引擎與模型授權聲明
```

---

## 授權與第三方聲明

- 本專案原始碼採用 [MIT License](LICENSE)。
- 本機推論所使用之 `wllama`、`llama.cpp`、`Emscripten`、`Dawn` 與 `PLaMo 3 Translate` 模型權重，皆依各自之開源與社群授權條款使用，詳見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
