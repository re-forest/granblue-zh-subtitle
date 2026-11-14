import { downloadHistoryFile } from "./export-log.js";

const card = document.querySelector("#card");
const speakerEl = document.querySelector("#speaker");
const badgeEl = document.querySelector("#stage-badge");
const captionEl = document.querySelector("#caption");
const originalEl = document.querySelector("#original");
const degradedEl = document.querySelector("#degraded-banner");
const historyEl = document.querySelector("#history");
const historyLabelEl = document.querySelector("#history-label");
const emptyEl = document.querySelector("#history-empty");
const exportBtn = document.querySelector("#export");
const clearBtn = document.querySelector("#clear");

const SETTINGS_KEY = "subtitleSettings";
const MAX_HISTORY = 25;
let activeFinal;
let lastLoggedKey = "";

function applySettings() {
  try {
    const saved = JSON.parse(localStorage.getItem(SETTINGS_KEY) || "{}");
    const scale = typeof saved.fontScale === "number" ? Math.min(1.4, Math.max(0.7, saved.fontScale)) : 1;
    document.documentElement.style.setProperty("--font-scale", String(scale));
  } catch {}
}

applySettings();
window.addEventListener("storage", event => {
  if (event.key === SETTINGS_KEY) applySettings();
});
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type === "subtitle-settings") {
    const scale = typeof message.settings?.fontScale === "number" ? message.settings.fontScale : 1;
    document.documentElement.style.setProperty("--font-scale", String(scale));
  }
  if (message.type === "close-sidepanel") {
    reply({ closed: true });
    window.close();
  }
});

exportBtn.addEventListener("click", async () => {
  const res = await chrome.runtime.sendMessage({ type: "get-history" }).catch(() => undefined);
  if (res?.entries?.length) downloadHistoryFile(res.entries);
});

clearBtn.addEventListener("click", () => {
  historyEl.replaceChildren(emptyEl);
  emptyEl.hidden = false;
  lastLoggedKey = "";
  activeFinal = undefined;
  exportBtn.disabled = true;
  historyLabelEl.textContent = "劇情回顧 (0 / 500)";
  void chrome.runtime.sendMessage({ type: "clear-history" }).catch(() => {});
});

function appendHistory(entry) {
  if (!entry?.sourceText) return;
  const key = `${entry.speaker}\n${entry.sourceText}\n${entry.caption}`;
  if (key === lastLoggedKey) return;
  lastLoggedKey = key;
  emptyEl.hidden = true;

  const item = document.createElement("article");
  item.className = "log-item";

  if (entry.speaker) {
    const sp = document.createElement("div");
    sp.className = "log-speaker";
    sp.textContent = entry.speaker;
    item.append(sp);
  }
  const zh = document.createElement("p");
  zh.className = "log-zh";
  zh.textContent = entry.caption;
  item.append(zh);

  const ja = document.createElement("p");
  ja.className = "log-ja";
  ja.textContent = entry.sourceText;
  item.append(ja);

  historyEl.prepend(item);
  while (historyEl.querySelectorAll(".log-item").length > MAX_HISTORY) {
    historyEl.querySelector(".log-item:last-of-type")?.remove();
  }
}

function renderState(state) {
  card.dataset.busy = String(Boolean(state.busy));
  card.dataset.error = String(Boolean(state.error));
  const backend = state.engineInfo?.backend;
  if (backend) card.dataset.backend = backend;
  else delete card.dataset.backend;

  const backendLabels = { cpu: "CPU", gpu: "WebGPU", server: "API" };
  const backendTag = backendLabels[backend] ?? "即時字幕";
  badgeEl.textContent = state.error ? "需要重試" : (state.busy ? "翻譯中…" : backendTag);

  const reason = state.engineInfo?.degradedReason;
  degradedEl.textContent = reason ?? "";
  degradedEl.hidden = !reason;

  if (typeof state.historyCount === "number") {
    const limit = state.historyLimit ?? 500;
    historyLabelEl.textContent = `劇情回顧 (${state.historyCount} / ${limit})`;
    exportBtn.disabled = state.historyCount <= 0;
  }

  speakerEl.textContent = state.speaker ?? "";
  speakerEl.hidden = !state.speaker;

  captionEl.classList.remove("entering");
  if (state.fade) void captionEl.offsetWidth;
  captionEl.textContent = state.caption || "等待劇情台詞…";
  if (state.fade) captionEl.classList.add("entering");

  const refText = state.original || state.sourceText || "";
  originalEl.textContent = refText;
  originalEl.hidden = !refText;

  // 新台詞翻譯完成時，將「上一句」推進歷史回顧，避免主舞台與歷史第一筆重複顯示
  if (state.final) {
    exportBtn.disabled = false;
    const nextKey = `${state.speaker ?? ""}\n${state.sourceText ?? ""}\n${state.caption}`;
    const prevKey = activeFinal ? `${activeFinal.speaker}\n${activeFinal.sourceText}\n${activeFinal.caption}` : "";
    if (activeFinal && nextKey !== prevKey) {
      appendHistory(activeFinal);
    }
    activeFinal = {
      speaker: state.speaker ?? "",
      caption: state.caption,
      sourceText: state.sourceText ?? ""
    };
  }
}

(async () => {
  try {
    const prepared = await chrome.runtime.sendMessage({ type: "prepare-subtitles" });
    if (!prepared?.ready) throw new Error(prepared?.error ?? "無法啟動翻譯引擎。");

    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab?.id) throw new Error("找不到作用中的遊戲分頁。");

    const port = chrome.runtime.connect({ name: "subtitle-sidepanel" });
    port.onMessage.addListener(message => {
      if (message.type === "state") renderState(message);
    });
    port.postMessage({ type: "start-sidepanel", tabId: tab.id });
  } catch (error) {
    renderState({ speaker: "", caption: error.message, original: "", busy: false, error: true });
  }
})();
