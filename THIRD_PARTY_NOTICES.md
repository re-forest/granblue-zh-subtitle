# 第三方軟體與模型授權聲明

《碧藍幻想繁中字幕》擴充功能原始碼採用 [MIT License](LICENSE) 釋出；專案運作所依賴的第三方推論引擎與語言模型權重，分別適用其各自之開源或社群授權條款。

## 1. 翻譯模型權重

- **PLaMo 3 Translate 0.8B (`plamo-3-translate-0.8b-Q4_K_M.gguf`)**
  - 授權條款：PLaMo Community License
  - 官方來源：https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF
  - 授權全文副本：
    - [extension/licenses/PLaMo-Community-License-en.txt](extension/licenses/PLaMo-Community-License-en.txt)
    - [extension/licenses/PLaMo-Community-License-ja.txt](extension/licenses/PLaMo-Community-License-ja.txt)
  - 備註：原始碼庫不包含大型模型檔案，需於使用本機推論前透過腳本或手動放置至 `extension/model/`。

## 2. 本機瀏覽器推論執行環境（`extension/vendor/wllama/`）

本專案使用編譯後的 `wllama` WebAssembly / WebGPU 執行環境於瀏覽器端載入 GGUF 模型：

- **wllama** — MIT License — Copyright (c) 2024 Xuan Son NGUYEN  
  授權全文：[extension/licenses/wllama-LICENSE.txt](extension/licenses/wllama-LICENSE.txt)
- **llama.cpp** — MIT License — Copyright (c) 2023-2026 The ggml authors  
  授權全文：[extension/licenses/llama.cpp-LICENSE.txt](extension/licenses/llama.cpp-LICENSE.txt)
- **Emscripten runtime** — MIT / University of Illinois/NCSA Open Source License — Copyright (c) 2010-2014 Emscripten authors  
  授權全文：[extension/licenses/emscripten-LICENSE.txt](extension/licenses/emscripten-LICENSE.txt)
- **Dawn emdawnwebgpu** — BSD-3-Clause — Copyright 2017-2026 The Dawn & Tint Authors  
  授權全文：[extension/licenses/dawn-LICENSE.txt](extension/licenses/dawn-LICENSE.txt)
