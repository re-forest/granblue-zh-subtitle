# 碧藍幻想繁中字幕 — iOS / iPadOS 原生版

專為 **iPhone 15 Pro Max（A17 Pro、8 GB RAM、iOS 17.0+）** 最佳化設計的單一原生 SwiftUI 應用程式。內嵌獨立 `WKWebView` 遊戲視窗與下方固定式雙語字幕艙，透過 `llama.cpp` Apple Metal 本機 GPU 或外部相容 LLM API 提供即時繁中翻譯。

---

## 主要功能

- **上下分區雙螢幕體驗**：上方約 78% 顯示遊戲畫面，下方約 22% 固定顯示繁中譯文與日文原文，完全不遮擋角色立繪或選項按鈕。
- **第三方帳號相容**：自動設定標準 iOS Safari User-Agent 並實作 `WKUIDelegate` 登入彈出視窗，相容 Mobage、DMM 與 Google OAuth 登入。
- **Metal 本機離線推論（含串流與快速翻頁中斷）**：
  - **PLaMo 0.8B Q4_K_M**（預設極速 · 約 547 MB）：首選推薦，翻譯流暢低耗電。
  - **PLaMo 2B Q4_K_M**（高精準選項 · 約 1.68 GB）：適合 iPhone 15 Pro Max 8 GB RAM 長句與複雜語氣翻譯。
  - **PLaMo 0.8B Q3_K_M**（輕量省空間 · 約 464 MB）：節省儲存空間。
  - **自備模型支援**：亦可透過 iOS「檔案」App 將自備 `.gguf` 匯入。
- **外部 API 模式**：支援連線區域網路內的 Ollama、LM Studio、`llama-server`（PLaMo 格式）或相容 OpenAI `/v1/chat/completions` 端點。
- **500 筆歷史紀錄與劇本匯出**：向左滑動字幕艙即可展開完整雙語紀錄清單，支援透過系統分享或儲存為含 UTF-8 BOM 的 `.txt` 劇本檔。

---

## 在 Windows 上開發與驗證

1. 執行本機橋接、詞庫與結構自動化測試（無需 macOS）：
   ```powershell
   node ios/Tests/verify-ios-bridge.mjs
   ```
2. 雲端編譯與產出實機 `.ipa`：
   - 推送變更至 GitHub 倉庫後，於 GitHub 分頁開啟 **Actions → Build iOS App → Run workflow**。
   - GitHub Actions 會在 `macos-15` Runner 上自動執行測試、下載 `llama.cpp` `b5046` XCFramework、透過 `XcodeGen` 產生 Xcode 專案、進行模擬器與實機編譯，並產出 `GBFSubtitle-unsigned.ipa`。

---

## 於 Windows 簽名安裝至 iPhone 實機（Sideloadly / SideStore）

1. 從 GitHub Actions 執行結果頁面下載 `GBFSubtitle-unsigned-ipa` 壓縮檔，解壓取得 `GBFSubtitle-unsigned.ipa`。
2. 在 Windows 開啟 [Sideloadly](https://sideloadly.io/)（或已配置好本機配對的 SideStore / AltServer）：
   - 使用 USB 線連接 iPhone 並信任電腦。
   - 將 `GBFSubtitle-unsigned.ipa` 拖入 Sideloadly，輸入自己的 Apple ID 後點擊 **Start**。
3. 初次安裝完成後，請於 iPhone 開啟「**設定 → 一般 → VPN 與裝置管理**」，信任對應開發者描述檔即可啟動。
4. 首次啟動若選用本機模型，請於設定面板點擊下載所需模型（建議切換至 Wi-Fi），下載完成後的模型會自動排除 iCloud 備份。
