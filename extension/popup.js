import { downloadHistoryFile } from "./export-log.js";

const button = document.querySelector("#toggle");
const sidePanelToggle = document.querySelector("#toggle-sidepanel");
const status = document.querySelector("#status");
const retry = document.querySelector("#retry");
const exportBtn = document.querySelector("#export-history");
const backendPill = document.querySelector("#backend-pill");
const fontScaleInput = document.querySelector("#font-scale");
const fontScaleValue = document.querySelector("#font-scale-value");
const autoFitInput = document.querySelector("#auto-fit");
const contextEnabledInput = document.querySelector("#context-enabled");
const modeButtons = [...document.querySelectorAll("[data-mode]")];
const serverConfigPanel = document.querySelector("#server-config");
const serverPresetSelect = document.querySelector("#server-preset");
const serverEndpointInput = document.querySelector("#server-endpoint");
const fieldModel = document.querySelector("#field-model");
const serverModelLabel = document.querySelector("#server-model-label");
const serverModelInput = document.querySelector("#server-model");
const fieldKey = document.querySelector("#field-key");
const serverKeyInput = document.querySelector("#server-key");
const fieldPlamo = document.querySelector("#field-plamo");
const serverUsePlamoInput = document.querySelector("#server-use-plamo");
const testServerBtn = document.querySelector("#test-server");
const serverTestResult = document.querySelector("#server-test-result");
const SERVER_PRESETS = {
  "llama-plamo": {
    endpoint: "http://127.0.0.1:8080",
    showModel: false,
    showKey: false,
    showPlamo: false
  },
  ollama: {
    endpoint: "http://127.0.0.1:11434",
    showModel: true,
    modelLabel: "模型名稱",
    modelPlaceholder: "例如 qwen2.5:7b、gemma2:9b",
    showKey: false,
    showPlamo: false
  },
  lmstudio: {
    endpoint: "http://127.0.0.1:1234",
    showModel: true,
    modelLabel: "模型名稱（單模型可留空）",
    modelPlaceholder: "例如 qwen2.5-7b-instruct",
    showKey: false,
    showPlamo: false
  },
  custom: {
    endpoint: "http://127.0.0.1:8000",
    showModel: true,
    modelLabel: "模型名稱（依伺服器需求填寫）",
    modelPlaceholder: "例如 Qwen/Qwen2.5-7B-Instruct、gpt-4o-mini",
    showKey: true,
    showPlamo: true
  }
};
const PRESET_DEFAULT_ENDPOINTS = new Set([
  ...Object.values(SERVER_PRESETS).map(p => p.endpoint),
  "http://127.0.0.1:8080/v1/completions",
  "http://127.0.0.1:8080/v1/chat/completions"
]);
const DEFAULT_SERVER_ENDPOINT = SERVER_PRESETS.ollama.endpoint;
const SETTINGS_KEY = "subtitleSettings";
let tabId;
let windowId;
let currentSettings;

function loadSettings() {
  try {
    const saved = JSON.parse(localStorage.getItem(SETTINGS_KEY) || "{}");
    const preset = SERVER_PRESETS[saved.serverPreset] ? saved.serverPreset : "ollama";
    return {
      fontScale: typeof saved.fontScale === "number" ? Math.min(1.4, Math.max(0.7, saved.fontScale)) : 1,
      autoFit: typeof saved.autoFit === "boolean" ? saved.autoFit : true,
      contextEnabled: typeof saved.contextEnabled === "boolean" ? saved.contextEnabled : true,
      inferenceMode: ["auto", "gpu", "cpu", "server"].includes(saved.inferenceMode) ? saved.inferenceMode : "auto",
      serverPreset: preset,
      serverEndpoint: typeof saved.serverEndpoint === "string" && saved.serverEndpoint.trim()
        ? saved.serverEndpoint.trim()
        : SERVER_PRESETS[preset].endpoint,
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

function applyPresetFields(presetKey) {
  const cfg = SERVER_PRESETS[presetKey] ?? SERVER_PRESETS["llama-plamo"];
  serverEndpointInput.placeholder = cfg.endpoint;
  fieldModel.hidden = !cfg.showModel;
  if (cfg.showModel) {
    serverModelLabel.textContent = cfg.modelLabel;
    serverModelInput.placeholder = cfg.modelPlaceholder;
  }
  fieldKey.hidden = !cfg.showKey;
  fieldPlamo.hidden = !cfg.showPlamo;
}

function applySettingsToUI(settings) {
  currentSettings = settings;
  const pct = Math.round(settings.fontScale * 100);
  fontScaleInput.value = String(pct);
  fontScaleValue.textContent = `${pct}%`;
  autoFitInput.checked = settings.autoFit;
  contextEnabledInput.checked = settings.contextEnabled;
  for (const btn of modeButtons) {
    btn.setAttribute("aria-checked", String(btn.dataset.mode === settings.inferenceMode));
  }
  serverConfigPanel.hidden = settings.inferenceMode !== "server";
  serverPresetSelect.value = settings.serverPreset;
  applyPresetFields(settings.serverPreset);
  if (document.activeElement !== serverEndpointInput) serverEndpointInput.value = settings.serverEndpoint;
  if (document.activeElement !== serverModelInput) serverModelInput.value = settings.serverModel;
  if (document.activeElement !== serverKeyInput) serverKeyInput.value = settings.serverApiKey;
  serverUsePlamoInput.checked = settings.serverUsePlamo;
}

function persistAndSyncSettings(partial = {}) {
  const preset = SERVER_PRESETS[partial.serverPreset ?? serverPresetSelect.value]
    ? (partial.serverPreset ?? serverPresetSelect.value)
    : "llama-plamo";
  const fallbackEndpoint = SERVER_PRESETS[preset].endpoint;
  const settings = {
    ...currentSettings,
    fontScale: Number(fontScaleInput.value) / 100,
    autoFit: autoFitInput.checked,
    contextEnabled: contextEnabledInput.checked,
    serverPreset: preset,
    serverEndpoint: serverEndpointInput.value.trim() || fallbackEndpoint,
    serverModel: serverModelInput.value.trim(),
    serverApiKey: serverKeyInput.value.trim(),
    serverUsePlamo: serverUsePlamoInput.checked,
    ...partial
  };
  applySettingsToUI(settings);
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
  } catch {}
  void chrome.runtime.sendMessage({ type: "subtitle-settings", settings }).catch(() => {});
  return settings;
}

async function ensureOriginPermission(endpoint) {
  let parsed;
  try {
    parsed = new URL(endpoint);
  } catch {
    return true;
  }
  if (parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost") return true;
  const originPattern = `${parsed.protocol}//${parsed.host}/*`;
  if (!chrome.permissions?.contains) return true;
  const has = await chrome.permissions.contains({ origins: [originPattern] }).catch(() => false);
  if (has) return true;
  return chrome.permissions.request({ origins: [originPattern] }).catch(() => false);
}

applySettingsToUI(loadSettings());
fontScaleInput.addEventListener("input", () => persistAndSyncSettings());
autoFitInput.addEventListener("change", () => persistAndSyncSettings());
contextEnabledInput.addEventListener("change", () => persistAndSyncSettings());
serverUsePlamoInput.addEventListener("change", () => persistAndSyncSettings());
serverPresetSelect.addEventListener("change", () => {
  const nextPreset = serverPresetSelect.value;
  const currentEndpoint = serverEndpointInput.value.trim();
  const nextEndpoint = (!currentEndpoint || PRESET_DEFAULT_ENDPOINTS.has(currentEndpoint))
    ? SERVER_PRESETS[nextPreset].endpoint
    : currentEndpoint;
  serverTestResult.textContent = "";
  persistAndSyncSettings({ serverPreset: nextPreset, serverEndpoint: nextEndpoint });
});
for (const input of [serverEndpointInput, serverModelInput, serverKeyInput]) {
  input.addEventListener("change", () => persistAndSyncSettings());
}
for (const btn of modeButtons) {
  btn.addEventListener("click", async () => {
    const mode = btn.dataset.mode;
    if (mode === currentSettings.inferenceMode) return;
    const saved = persistAndSyncSettings({ inferenceMode: mode });
    if (mode === "server") await ensureOriginPermission(saved.serverEndpoint);
    if (button.checked || sidePanelToggle.checked) {
      status.dataset.tone = "info";
      status.textContent = `已切換為「${btn.textContent}」推論模式，正在切換引擎…`;
    }
  });
}

testServerBtn.addEventListener("click", async () => {
  const saved = persistAndSyncSettings();
  testServerBtn.disabled = true;
  serverTestResult.dataset.tone = "info";
  serverTestResult.textContent = "連線測試中…";
  try {
    const granted = await ensureOriginPermission(saved.serverEndpoint);
    if (!granted) throw new Error("未授予該網域的連線權限。");
    const res = await chrome.runtime.sendMessage({
      type: "test-llm-server",
      config: {
        preset: saved.serverPreset,
        endpoint: saved.serverEndpoint,
        model: saved.serverModel,
        apiKey: saved.serverApiKey,
        usePlamoFormat: saved.serverUsePlamo
      }
    });
    if (!res?.ok) throw new Error(res?.error ?? "連線失敗。");
    serverTestResult.dataset.tone = "ok";
    serverTestResult.textContent = `連線成功 (${res.latencyMs} ms)`;
  } catch (error) {
    serverTestResult.dataset.tone = "error";
    serverTestResult.textContent = error.message;
  } finally {
    testServerBtn.disabled = false;
  }
});

function updateBackendPill(engineInfo) {
  if (!engineInfo?.backend) {
    backendPill.hidden = true;
    return;
  }
  backendPill.hidden = false;
  backendPill.dataset.backend = engineInfo.backend;
  const labels = { gpu: "WebGPU", cpu: "CPU", server: "API" };
  backendPill.textContent = labels[engineInfo.backend] ?? "CPU";
}

function formatStatus(pipEnabled, sidePanelEnabled, error, engineInfo, loadingStatus) {
  if (error) return { text: error, tone: "error" };
  if ((pipEnabled || sidePanelEnabled) && loadingStatus) {
    return { text: loadingStatus, tone: "info" };
  }
  if (engineInfo?.degradedReason && (pipEnabled || sidePanelEnabled)) {
    return { text: engineInfo.degradedReason, tone: "warn" };
  }
  if (pipEnabled && sidePanelEnabled) return { text: "懸浮與側邊欄字幕已開啟", tone: "info" };
  if (pipEnabled) return { text: "懸浮字幕已開啟", tone: "info" };
  if (sidePanelEnabled) return { text: "側邊欄字幕已開啟", tone: "info" };
  return { text: "字幕已關閉", tone: "info" };
}

let historyLimit = 500;

function updateExportButton(count = 0, limit = historyLimit) {
  historyLimit = limit;
  exportBtn.disabled = count <= 0;
  exportBtn.textContent = `匯出翻譯紀錄 (${count} / ${limit})`;
}

function showState(state) {
  const pipEnabled = Boolean(state.enabled);
  const sidePanelEnabled = Boolean(state.sidePanelEnabled);
  button.checked = pipEnabled;
  sidePanelToggle.checked = sidePanelEnabled;
  updateBackendPill(state.engineInfo);
  if (typeof state.historyCount === "number") updateExportButton(state.historyCount, state.historyLimit);
  const { text, tone } = formatStatus(pipEnabled, sidePanelEnabled, state.error, state.engineInfo, state.loadingStatus);
  status.dataset.tone = tone;
  status.textContent = text;
  retry.hidden = !state.error || (!pipEnabled && !sidePanelEnabled);
  button.disabled = false;
  sidePanelToggle.disabled = !Number.isInteger(windowId);
}

(async () => {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    tabId = tab?.id;
    windowId = tab?.windowId;
    const prepared = await chrome.runtime.sendMessage({ type: "prepare-subtitles" });
    if (!prepared?.ready) throw new Error(prepared?.error ?? "無法準備字幕窗。");
    const state = await chrome.runtime.sendMessage({ type: "subtitle-status" });
    if (!state || (state.error && !state.enabled && !state.sidePanelEnabled)) {
      throw new Error(state?.error ?? "字幕窗未回應。");
    }
    if (typeof state.historyCount === "number") updateExportButton(state.historyCount, state.historyLimit);
    if (!state.enabled && !state.sidePanelEnabled) {
      const source = await chrome.tabs.sendMessage(tabId, { type: "subtitle-source-status" }, { frameId: 0 }).catch(() => undefined);
      if (!source?.available) {
        status.dataset.tone = "info";
        status.textContent = "請切到《碧藍幻想》的遊戲分頁，或重新整理遊戲頁。";
        return;
      }
    }
    showState(state);
  } catch (error) {
    status.dataset.tone = "error";
    status.textContent = error.message;
  }
})();

button.addEventListener("change", async () => {
  const requested = button.checked;
  button.checked = !requested;
  button.disabled = true;
  status.dataset.tone = "info";
  status.textContent = requested ? "正在開啟懸浮字幕…" : "正在關閉懸浮字幕…";
  try {
    // 由 popup 直接送訊給 offscreen engine.html，保留使用者手勢以開啟 Video PiP
    const state = await chrome.runtime.sendMessage({ type: "toggle-subtitle-window", tabId });
    if (!state || state.error) throw new Error(state?.error ?? "字幕窗未回應。");
    showState(state);
    if (!state.enabled && !state.sidePanelEnabled) window.close();
  } catch (error) {
    status.dataset.tone = "error";
    status.textContent = error.message;
    button.disabled = false;
  }
});

sidePanelToggle.addEventListener("change", async () => {
  const requested = sidePanelToggle.checked;
  sidePanelToggle.checked = !requested;
  sidePanelToggle.disabled = true;
  status.dataset.tone = "info";
  status.textContent = requested ? "正在開啟側邊欄字幕…" : "正在關閉側邊欄字幕…";
  try {
    if (requested) {
      if (!Number.isInteger(windowId)) throw new Error("找不到目前視窗。");
      await chrome.sidePanel.open({ windowId });
      showState({ enabled: button.checked, sidePanelEnabled: true });
      window.close();
    } else {
      await chrome.runtime.sendMessage({ type: "close-sidepanel" }).catch(() => {});
      showState({ enabled: button.checked, sidePanelEnabled: false });
      if (!button.checked) window.close();
    }
  } catch (error) {
    status.dataset.tone = "error";
    status.textContent = error.message;
    sidePanelToggle.disabled = false;
  }
});

exportBtn.addEventListener("click", async () => {
  const res = await chrome.runtime.sendMessage({ type: "get-history" }).catch(() => undefined);
  if (res?.entries?.length) downloadHistoryFile(res.entries);
});

retry.addEventListener("click", async () => {
  retry.disabled = true;
  try {
    const state = await chrome.runtime.sendMessage({ type: "retry-subtitles" });
    if (!state?.enabled) throw new Error("字幕窗已關閉，請重新開啟。");
    showState({ ...state, sidePanelEnabled: sidePanelToggle.checked });
    status.dataset.tone = "info";
    status.textContent = "正在載入翻譯模型…";
  } catch (error) {
    status.dataset.tone = "error";
    status.textContent = error.message;
  } finally {
    retry.disabled = false;
  }
});
