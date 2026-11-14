import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const iosRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(iosRoot, "..");

function readUtf8(relPath) {
  return fs.readFileSync(path.join(repoRoot, relPath), "utf8");
}

function testBridgeScript() {
  const scriptSource = readUtf8("ios/GBFSubtitleApp/Resources/content-ios.js");
  const postedMessages = [];
  const windowListeners = new Map();
  let observerCallback = null;
  let observerDisconnected = false;

  // 模擬頁面上三個對話框：第 1 個可見但較舊，第 2 個可見且最新，第 3 個尚未展開（getClientRects 為空）
  const mockBoxes = [
    {
      speaker: "ビィ",
      text: "おいらに任せな！",
      rects: [{ width: 120, height: 24 }]
    },
    {
      speaker: "ルリア（水着）",
      text: "さあ、みんなで行こう！",
      rects: [{ width: 220, height: 28 }]
    },
    {
      speaker: "カタリナ",
      text: "次のエリアへ進むぞ。",
      rects: []
    }
  ];

  function createBoxElement(item) {
    return {
      querySelector(selector) {
        if (selector === ".txt-message") {
          return {
            innerText: item.text,
            getClientRects: () => item.rects
          };
        }
        if (selector === ".txt-character-name") {
          return item.speaker ? { innerText: item.speaker } : null;
        }
        return null;
      }
    };
  }

  class MockMutationObserver {
    constructor(cb) {
      observerCallback = cb;
      observerDisconnected = false;
    }
    observe() {}
    disconnect() {
      observerDisconnected = true;
    }
  }

  let mockDungeonComment = null;
  let mockChoices = [];

  const sandbox = {
    location: { href: "https://game.granbluefantasy.jp/#quest/scene/1" },
    getComputedStyle(el) {
      return { visibility: el.visibility ?? "visible" };
    },
    document: {
      readyState: "complete",
      body: {},
      querySelector(selector) {
        if (selector.includes("#js-prt-dungeon-temporary-choices.active")) {
          return mockDungeonComment;
        }
        return null;
      },
      querySelectorAll(selector) {
        if (selector.includes(".btn-select-balloon")) {
          return mockChoices;
        }
        if (selector === ".prt-scene-comment") {
          return mockBoxes.map(createBoxElement);
        }
        return [];
      },
      addEventListener() {}
    },
    MutationObserver: MockMutationObserver,
    setTimeout,
    clearTimeout,
    window: null
  };

  sandbox.window = {
    location: sandbox.location,
    webkit: {
      messageHandlers: {
        subtitleBridge: {
          postMessage(payload) {
            postedMessages.push(JSON.parse(JSON.stringify(payload)));
          }
        }
      }
    },
    addEventListener(type, fn) {
      windowListeners.set(type, fn);
    },
    removeEventListener(type) {
      windowListeners.delete(type);
    }
  };
  sandbox.globalThis = sandbox;

  vm.runInNewContext(scriptSource, sandbox, { filename: "content-ios.js" });

  assert.equal(postedMessages[0]?.type, "subtitle-source-ready", "初始化時必須發送 subtitle-source-ready");
  assert.deepEqual(
    { speaker: postedMessages[1]?.speaker, text: postedMessages[1]?.text },
    { speaker: "ルリア（水着）", text: "さあ、みんなで行こう！" },
    "應優先擷取最後一個可見的 .prt-scene-comment 對話框"
  );

  // 模擬對話框內容未變更時再度觸發 DOM 變動 -> 必須去重
  const countBeforeDup = postedMessages.length;
  observerCallback();
  assert.equal(postedMessages.length, countBeforeDup, "相同台詞不應重複發送給原生端");

  // 模擬第 3 個對話框完成展開（getClientRects 變成非空），並等待 120ms 延遲檢查
  mockBoxes[2].rects = [{ width: 200, height: 24 }];
  observerCallback();
  assert.deepEqual(
    { speaker: postedMessages.at(-1)?.speaker, text: postedMessages.at(-1)?.text },
    { speaker: "カタリナ", text: "次のエリアへ進むぞ。" },
    "應立即擷取新展開的台詞"
  );

  // 測試 120ms 延遲補抓場景：先以空白 rects 觸發，再於 40ms 後展開動畫完成
  mockBoxes.push({
    speaker: "グラン",
    text: "よし、出発だ！",
    rects: []
  });
  observerCallback();
  setTimeout(() => {
    mockBoxes[3].rects = [{ width: 180, height: 24 }];
  }, 40);

  return new Promise(resolve => {
    setTimeout(() => {
      assert.deepEqual(
        { speaker: postedMessages.at(-1)?.speaker, text: postedMessages.at(-1)?.text },
        { speaker: "グラン", text: "よし、出発だ！" },
        "120ms 動畫延遲檢查必須能補抓到延遲展開的台詞"
      );

      // 驗證停止與手動重檢介面
      sandbox.window.__gbfSubtitleBridge.stopWatching();
      assert.equal(observerDisconnected, true, "stopWatching 必須中斷 MutationObserver");
      sandbox.window.__gbfSubtitleBridge.forceCheck();
      assert.equal(observerDisconnected, false, "forceCheck 應重新啟動觀察並重送目前台詞");

      // 驗證轉世地城事件對話 (#js-prt-dungeon-temporary-choices.active) 優先擷取
      mockDungeonComment = {
        innerText: "奇妙な気配が漂っている……",
        getClientRects: () => [{ width: 200, height: 24 }]
      };
      observerCallback();
      assert.deepEqual(
        { speaker: postedMessages.at(-1)?.speaker, text: postedMessages.at(-1)?.text },
        { speaker: "", text: "奇妙な気配が漂っている……" },
        "應能正確擷取轉世地城事件對話"
      );

      // 驗證劇情選項與地城選項擷取（應過濾 visibility !== visible 與折行壓縮）
      mockChoices = [
        { innerText: "先へ\n進む", visibility: "visible", getClientRects: () => [{ width: 120, height: 30 }] },
        { innerText: "隱藏選項", visibility: "hidden", getClientRects: () => [{ width: 120, height: 30 }] },
        { innerText: "引き返す", visibility: "visible", getClientRects: () => [{ width: 120, height: 30 }] }
      ];
      observerCallback();
      assert.deepEqual(
        { speaker: postedMessages.at(-1)?.speaker, text: postedMessages.at(-1)?.text },
        { speaker: "", text: "1. 先へ 進む\n2. 引き返す" },
        "應優先擷取可見選項並加上編號"
      );
      mockChoices = [];
      mockDungeonComment = null;
      resolve();
    }, 180);
  });
}

function testGlossaryAndPromptRules() {
  const extNamesRaw = readUtf8("extension/data/character-names.json");
  const iosNamesRaw = readUtf8("ios/GBFSubtitleApp/Resources/character-names.json");
  assert.equal(iosNamesRaw, extNamesRaw, "iOS 端角色譯名表必須與主擴充功能完全一致");

  const map = JSON.parse(iosNamesRaw);
  const resolveSpeaker = raw => {
    const name = raw.trim();
    if (!name) return "";
    if (map[name]) return map[name];
    const base = name.replace(/[（(].*?[)）]$/g, "").trim();
    return map[base] ?? name;
  };

  assert.equal(resolveSpeaker("ルリア（水着）"), "露莉亞", "應正確去除括號尾綴並轉換角色譯名");
  assert.equal(resolveSpeaker("カタリナ・アリーゼ"), "卡塔莉娜", "應優先精確匹配全名");

  const sortedEntries = Object.entries(map)
    .filter(([jp, zh]) => jp && zh && !/^[？?]+$/.test(jp))
    .sort((a, b) => (b[0].length - a[0].length) || a[0].localeCompare(b[0]));

  const extractGlossary = (text, maxCount = 8) => {
    const matched = [];
    let remaining = text;
    for (const [jp, zh] of sortedEntries) {
      if (!remaining.includes(jp)) continue;
      matched.push([jp, zh]);
      remaining = remaining.replaceAll(jp, "\0");
      if (matched.length >= maxCount) break;
    }
    return matched;
  };

  const pairs = extractGlossary("カタリナ・アリーゼとルリアとビィが一緒に戦う！");
  assert.equal(pairs[0][0], "カタリナ・アリーゼ", "長詞必須優先匹配並遮蔽短詞カタリナ");
  assert.ok(!pairs.some(([jp]) => jp === "カタリナ"), "被遮蔽的短詞不應重複出現");
  assert.ok(pairs.some(([jp]) => jp === "ルリア"));
  assert.ok(pairs.some(([jp]) => jp === "ビィ"));
}

function testSwiftModelsAndProjectIntegrity() {
  const expectedFiles = [
    "ios/project.yml",
    "ios/scripts/fetch-llama-xcframework.sh",
    "ios/GBFSubtitleApp/Info.plist",
    "ios/GBFSubtitleApp/Resources/character-names.json",
    "ios/GBFSubtitleApp/Resources/content-ios.js",
    "ios/GBFSubtitleApp/Sources/GBFSubtitleApp.swift",
    "ios/GBFSubtitleApp/Sources/Models/SubtitleModels.swift",
    "ios/GBFSubtitleApp/Sources/Services/GlossaryMatcher.swift",
    "ios/GBFSubtitleApp/Sources/Services/ModelDownloadManager.swift",
    "ios/GBFSubtitleApp/Sources/Services/TranslationEngine.swift",
    "ios/GBFSubtitleApp/Sources/Services/SubtitleSessionManager.swift",
    "ios/GBFSubtitleApp/Sources/WebView/GBFWebView.swift",
    "ios/GBFSubtitleApp/Sources/Views/MainSplitView.swift",
    "ios/GBFSubtitleApp/Sources/Views/SubtitleDeckView.swift",
    "ios/GBFSubtitleApp/Sources/Views/HistoryDrawerView.swift",
    "ios/GBFSubtitleApp/Sources/Views/SettingsSheetView.swift",
    ".github/workflows/ios-build.yml",
    "ios/README.md"
  ];

  for (const file of expectedFiles) {
    assert.equal(fs.existsSync(path.join(repoRoot, file)), true, `缺少必要檔案：${file}`);
  }

  const modelsSwift = readUtf8("ios/GBFSubtitleApp/Sources/Models/SubtitleModels.swift");
  assert.ok(modelsSwift.includes("plamo-3-translate-0.8b-Q4_K_M.gguf"));
  assert.ok(modelsSwift.includes("plamo-3-translate-2b-Q4_K_M.gguf"));
  assert.ok(modelsSwift.includes("plamo-3-translate-0.8b-Q3_K_M.gguf"));
  assert.equal(modelsSwift.includes("0.8b-Q8_0.gguf"), false, "不應參考官方倉庫不存在的 0.8b-Q8_0.gguf");

  const glossarySwift = readUtf8("ios/GBFSubtitleApp/Sources/Services/GlossaryMatcher.swift");
  assert.ok(glossarySwift.includes("0xEF, 0xBB, 0xBF"), "劇本匯出必須包含 UTF-8 BOM");
  assert.ok(glossarySwift.includes("＜|plamo:"), "必須包含 PLaMo 控制標籤跳脫規則");

  const sessionSwift = readUtf8("ios/GBFSubtitleApp/Sources/Services/SubtitleSessionManager.swift");
  assert.ok(sessionSwift.includes("maxHistoryCount = 500"), "歷史紀錄上限必須為 500 筆");

  const engineSwift = readUtf8("ios/GBFSubtitleApp/Sources/Services/TranslationEngine.swift");
  assert.ok(engineSwift.includes("llama_kv_self_clear"), "必須對齊 llama.cpp b5046 KV 清除介面");
  assert.ok(engineSwift.includes("llama_sampler_init_greedy"), "必須對齊 llama.cpp b5046 Sampler 介面");

  const downloadSwift = readUtf8("ios/GBFSubtitleApp/Sources/Services/ModelDownloadManager.swift");
  assert.ok(downloadSwift.includes("import Combine"), "ModelDownloadManager 必須引入 Combine 以支援 @Published");
}

await testBridgeScript();
testGlossaryAndPromptRules();
testSwiftModelsAndProjectIntegrity();
console.log("PASS: iOS WebKit 橋接、詞庫對齊、模型規格與檔案完整性驗證全部通過。");
