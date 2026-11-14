import {
  DEFAULT_SERVER_ENDPOINT,
  getEngineInfo,
  loadEngine,
  setServerConfig,
  testServerConnection,
  translate,
  unloadEngine
} from "./engine.js";
import { createPipRenderer } from "./pip-renderer.js";

function loadSettings() {
  try {
    const saved = JSON.parse(localStorage.getItem("subtitleSettings") || "{}");
    return {
      fontScale: typeof saved.fontScale === "number" ? saved.fontScale : 1,
      autoFit: typeof saved.autoFit === "boolean" ? saved.autoFit : true,
      contextEnabled: typeof saved.contextEnabled === "boolean" ? saved.contextEnabled : true,
      inferenceMode: ["auto", "gpu", "cpu", "server"].includes(saved.inferenceMode) ? saved.inferenceMode : "auto",
      serverPreset: ["ollama", "lmstudio", "custom", "llama-plamo"].includes(saved.serverPreset)
        ? saved.serverPreset
        : "ollama",
      serverEndpoint: typeof saved.serverEndpoint === "string" && saved.serverEndpoint.trim()
        ? saved.serverEndpoint.trim()
        : DEFAULT_SERVER_ENDPOINT,
      serverModel: typeof saved.serverModel === "string" ? saved.serverModel.trim() : "",
      serverApiKey: typeof saved.serverApiKey === "string" ? saved.serverApiKey.trim() : "",
      serverUsePlamo: Boolean(saved.serverUsePlamo)
    };
  } catch {
    return {
      fontScale: 1,
      autoFit: true,
      contextEnabled: true,
      inferenceMode: "auto",
      serverPreset: "ollama",
      serverEndpoint: DEFAULT_SERVER_ENDPOINT,
      serverModel: "",
      serverApiKey: "",
      serverUsePlamo: false
    };
  }
}

const initialSettings = loadSettings();
let inferenceMode = initialSettings.inferenceMode;
let contextEnabled = initialSettings.contextEnabled;
setServerConfig({
  preset: initialSettings.serverPreset,
  endpoint: initialSettings.serverEndpoint,
  model: initialSettings.serverModel,
  apiKey: initialSettings.serverApiKey,
  usePlamoFormat: initialSettings.serverUsePlamo
});
const renderer = createPipRenderer(initialSettings);
const video = document.createElement("video");
video.muted = true;
video.playsInline = true;
video.srcObject = renderer.stream;

const videoReady = new Promise(resolve => {
  if (video.readyState >= 1) {
    resolve();
  } else {
    video.addEventListener("loadedmetadata", resolve, { once: true });
  }
}).then(() => video.play().catch(() => {}));

let characterNames = {};
let sortedGlossaryEntries = [];
const namesReady = fetch(chrome.runtime.getURL("data/character-names.json"))
  .then(res => (res.ok ? res.json() : {}))
  .then(map => {
    characterNames = map ?? {};
    sortedGlossaryEntries = Object.entries(characterNames)
      .filter(([jp, zh]) => jp && zh && !/^[？?]+$/.test(jp))
      .sort((a, b) => b[0].length - a[0].length);
  })
  .catch(() => {});

function extractGlossary(text) {
  if (!text || !sortedGlossaryEntries.length) return [];
  const matched = [];
  let remaining = text;
  for (const [jp, zh] of sortedGlossaryEntries) {
    if (!remaining.includes(jp)) continue;
    matched.push([jp, zh]);
    // 遮蔽已命中的長名稱，避免短名稱重複命中同一片段
    remaining = remaining.replaceAll(jp, "\0");
    if (matched.length >= 8) break;
  }
  return matched;
}

function buildContext(history, currentText) {
  if (!contextEnabled || !history?.length) return "";
  return history
    .filter(item => item.text && item.text !== currentText)
    .slice(-2)
    .map(item => (item.speaker ? `${item.speaker}：${item.text}` : item.text))
    .join("\n");
}

let session;
let sidePanelPort;
let lastPayload;
let modelReady = false;
let loadingText = "";
let running = false;
let toggling = false;
let lastLineChange = -Infinity;
let skipFade = false;
const MAX_HISTORY_LOG = 500;
const translationLog = [];

function recordTranslation(speaker, zh, ja) {
  if (!ja || !zh) return;
  const last = translationLog[translationLog.length - 1];
  if (last && last.speaker === speaker && last.ja === ja && last.zh === zh) return;
  const now = new Date();
  const pad = n => String(n).padStart(2, "0");
  const time = `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
  translationLog.push({ time, speaker, zh, ja });
  if (translationLog.length > MAX_HISTORY_LOG) translationLog.shift();
}

function resolveSpeaker(raw) {
  const name = raw?.trim() ?? "";
  if (!name) return "";
  if (characterNames[name]) return characterNames[name];
  const base = name.replace(/[（(].*?[)）]$/g, "").trim();
  return characterNames[base] ?? name;
}

function render(caption, { showOriginal = false, fade = false, busy = false, error = false } = {}) {
  const line = session?.line;
  const payload = {
    speaker: resolveSpeaker(line?.speaker),
    caption,
    original: showOriginal ? (line?.text ?? "") : "",
    sourceText: line?.text ?? "",
    busy,
    error,
    final: !busy && !error && Boolean(line?.text),
    historyCount: translationLog.length,
    historyLimit: MAX_HISTORY_LOG,
    engineInfo: getEngineInfo()
  };
  lastPayload = payload;
  if (session?.mode === "pip" || document.pictureInPictureElement === video) {
    renderer.update(payload, { fade });
  }
  sidePanelPort?.postMessage({ type: "state", ...payload, fade });
}

function setLine(line) {
  if (!session) return;
  if (line.text) {
    const now = performance.now();
    skipFade = now - lastLineChange <= 180;
    lastLineChange = now;
  }
  session.line = line;
  session.pending = Boolean(line.text);
  const pendingCaption = modelReady ? "正在翻譯…" : (loadingText || "首次載入翻譯模型…");
  render(session.error ?? (line.text
    ? pendingCaption
    : (loadingText || "等待劇情台詞…")), {
    showOriginal: !modelReady || Boolean(session.error),
    busy: (Boolean(line.text) || Boolean(loadingText)) && !session.error,
    error: Boolean(session.error)
  });
  void processLatest();
}

async function processLatest() {
  if (running || !session || session.error || (modelReady && !session.pending)) return;
  running = true;
  let work = session;
  try {
    await namesReady;
    if (!modelReady) {
      work.hasTranslatedOnce = false;
      loadingText = "首次載入翻譯模型…";
      let lastProgressUi = 0;
      await loadEngine(inferenceMode, undefined, progress => {
        if (!session || session.error) return;
        const now = performance.now();
        if (progress?.phase === "downloading") {
          if (now - lastProgressUi < 350 && progress.percent !== 0) return;
          lastProgressUi = now;
          const detail = typeof progress.percent === "number"
            ? `${progress.percent}% · ${progress.loadedMB} / ${progress.totalMB} MB`
            : `${progress.loadedMB} MB`;
          loadingText = `首次下載翻譯模型中 (${detail})…`;
          render(loadingText, { showOriginal: true, busy: true });
        } else if (progress?.phase === "loading") {
          loadingText = "正在初始化翻譯模型…";
          render(loadingText, { showOriginal: true, busy: true });
        }
      });
      loadingText = "";
      modelReady = true;
      if (session && !session.line?.text) {
        render("等待劇情台詞…", { busy: false });
      }
    }
    while (session?.pending && !session.error) {
      work = session;
      const line = work.line;
      work.pending = false;
      if (line.text.length > 1000) {
        render("這句台詞超出翻譯長度上限。", { showOriginal: true, error: true });
        continue;
      }
      render("正在翻譯…", { showOriginal: !work.hasTranslatedOnce, busy: true });
      try {
        const glossary = extractGlossary(line.text);
        const context = buildContext(work.history, line.text);
        const result = await translate(line.text, {
          glossary,
          context,
          speaker: resolveSpeaker(line.speaker)
        });
        if (session === work && work.line === line) {
          work.hasTranslatedOnce = true;
          work.history = (work.history ?? []).filter(item => item.text !== line.text);
          work.history.push({ speaker: line.speaker, text: line.text });
          if (work.history.length > 2) work.history.shift();
          recordTranslation(resolveSpeaker(line.speaker), result, line.text);
          render(result, { fade: !skipFade, busy: false });
        }
      } catch (error) {
        if (session === work && work.line === line) {
          render(error.message, { showOriginal: true, error: true });
        }
      }
    }
  } catch (error) {
    loadingText = "";
    if (session === work && error?.message !== "已取消模型下載。") {
      work.error = error.message;
      render(work.error, { showOriginal: true, error: true });
    }
  } finally {
    running = false;
    if (session && session !== work) void processLatest();
  }
}

function stopSession() {
  if (!session) return;
  loadingText = "";
  lastLineChange = -Infinity;
  const { tabId } = session;
  session = undefined;
  renderer.update({ speaker: "", caption: "等待劇情台詞…", original: "", busy: false, error: false });
  sidePanelPort?.postMessage({ type: "state", speaker: "", caption: "等待劇情台詞…", original: "", busy: false, error: false, final: false });
  void chrome.runtime.sendMessage({ type: "stop-subtitles", tabId }).catch(() => {});
}

video.addEventListener("leavepictureinpicture", () => {
  if (!sidePanelPort) {
    stopSession();
  } else if (session) {
    session.mode = "sidepanel";
  }
});

chrome.runtime.onConnect.addListener(port => {
  if (port.name !== "subtitle-sidepanel" ||
      port.sender?.url !== chrome.runtime.getURL("sidepanel.html")) return;
  sidePanelPort = port;
  port.onMessage.addListener(message => {
    if (message.type !== "start-sidepanel" || !Number.isInteger(message.tabId)) return;
    if (!session) {
      session = { tabId: message.tabId, mode: "sidepanel", line: {} };
      setLine({});
      void chrome.runtime.sendMessage({ type: "watch-subtitles", tabId: message.tabId }).catch(() => {});
    } else if (lastPayload) {
      sidePanelPort?.postMessage({ type: "state", ...lastPayload, fade: false });
    }
  });
  port.onDisconnect.addListener(() => {
    if (sidePanelPort === port) sidePanelPort = undefined;
    if (document.pictureInPictureElement !== video) {
      stopSession();
    } else if (session) {
      session.mode = "pip";
    }
  });
});

async function togglePip(tabId) {
  if (toggling) return { error: "字幕窗正在切換，請稍後再試。" };
  toggling = true;
  try {
    if (document.pictureInPictureElement === video) {
      await document.exitPictureInPicture().catch(() => {});
      if (!sidePanelPort) {
        stopSession();
      } else if (session) {
        session.mode = "sidepanel";
      }
      return { enabled: false, sidePanelEnabled: Boolean(sidePanelPort) };
    }
    if (!Number.isInteger(tabId)) {
      return { error: "找不到遊戲分頁，請切回遊戲分頁後重試。" };
    }
    await Promise.all([videoReady, namesReady]);
    const reusing = Boolean(session);
    if (!session) {
      session = { tabId, mode: "pip", line: {} };
      setLine({});
    } else {
      session.mode = "pip";
      if (lastPayload) renderer.update(lastPayload, { fade: false });
    }
    await video.requestPictureInPicture();
    if (!reusing) {
      void chrome.runtime.sendMessage({ type: "watch-subtitles", tabId }).catch(() => {});
    }
    return { enabled: true, sidePanelEnabled: Boolean(sidePanelPort) };
  } catch (error) {
    if (!sidePanelPort) stopSession();
    return { error: error.message };
  } finally {
    toggling = false;
  }
}

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  const popup = sender.url === chrome.runtime.getURL("popup.html");
  const sidepanel = sender.url === chrome.runtime.getURL("sidepanel.html");
  const worker = sender.url === chrome.runtime.getURL("background.js");
  if ((popup || sidepanel) && message.type === "get-history") {
    reply({ entries: translationLog });
    return;
  }
  if ((popup || sidepanel) && message.type === "clear-history") {
    translationLog.length = 0;
    reply({ cleared: true });
    return;
  }
  if (popup && message.type === "test-llm-server") {
    testServerConnection(message.config)
      .then(result => reply(result))
      .catch(error => reply({ ok: false, error: error.message }));
    return true;
  }
  if (popup && message.type === "subtitle-settings") {
    renderer.setSettings(message.settings);
    if (typeof message.settings?.contextEnabled === "boolean") {
      contextEnabled = message.settings.contextEnabled;
    }
    if (typeof message.settings?.serverEndpoint === "string" ||
        typeof message.settings?.serverModel === "string" ||
        typeof message.settings?.serverApiKey === "string" ||
        typeof message.settings?.serverPreset === "string") {
      setServerConfig({
        preset: message.settings.serverPreset,
        endpoint: message.settings.serverEndpoint,
        model: message.settings.serverModel,
        apiKey: message.settings.serverApiKey,
        usePlamoFormat: message.settings.serverUsePlamo
      });
    }
    const nextMode = message.settings?.inferenceMode;
    if (["auto", "gpu", "cpu", "server"].includes(nextMode) && nextMode !== inferenceMode) {
      inferenceMode = nextMode;
      modelReady = false;
      loadingText = "";
      if (session) session.hasTranslatedOnce = false;
      void unloadEngine().then(() => {
        if (session) {
          session.error = undefined;
          setLine(session.line ?? {});
        }
      });
    }
    return;
  }
  if (popup && message.type === "subtitle-status") {
    videoReady.then(() => {
      reply({
        enabled: Boolean(session) && document.pictureInPictureElement === video,
        sidePanelEnabled: Boolean(sidePanelPort),
        historyCount: translationLog.length,
        historyLimit: MAX_HISTORY_LOG,
        error: session?.error,
        loadingStatus: !modelReady && session ? (loadingText || "首次載入翻譯模型…") : "",
        engineInfo: getEngineInfo()
      });
    });
    return true;
  }
  if (popup && message.type === "toggle-subtitle-window") {
    togglePip(message.tabId).then(reply);
    return true;
  }
  if (popup && message.type === "retry-subtitles" && session?.error) {
    session.error = undefined;
    setLine(session.line);
    reply({ enabled: true });
    return;
  }
  if (!session) return;
  if (worker && message.tabId === session.tabId) {
    if (message.type === "source-closed") {
      if (document.pictureInPictureElement === video) {
        void document.exitPictureInPicture().catch(() => {});
      }
      stopSession();
    }
    if (message.type === "source-loading") setLine({});
    return;
  }
  const game = sender.tab?.id === session.tabId && sender.frameId === 0 &&
    sender.url?.startsWith("https://game.granbluefantasy.jp/");
  if (!game) return;
  if (message.type === "subtitle-source-ready") {
    session.documentId = sender.documentId;
    reply({ enabled: true });
  }
  if (message.type === "subtitle-line" &&
      (!session.documentId || session.documentId === sender.documentId) &&
      typeof message.text === "string" && typeof message.speaker === "string") {
    session.documentId = sender.documentId;
    setLine({ text: message.text, speaker: message.speaker });
  }
});
