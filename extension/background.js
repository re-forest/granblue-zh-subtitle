const enginePage = "engine.html";
let openingEngine;

async function ensureEngine() {
  if (!openingEngine) {
    openingEngine = (async () => {
      const contexts = await chrome.runtime.getContexts({
        contextTypes: ["OFFSCREEN_DOCUMENT"],
        documentUrls: [chrome.runtime.getURL(enginePage)]
      });
      if (!contexts.length) {
        await chrome.offscreen.createDocument({
          url: enginePage,
          reasons: ["WORKERS"],
          justification: "保持 WebGPU 翻譯模型與離屏字幕畫面可用。"
        });
      }
    })().finally(() => { openingEngine = undefined; });
  }
  await openingEngine;
}

const allowedPrepareSenders = new Set([
  chrome.runtime.getURL("popup.html"),
  chrome.runtime.getURL("sidepanel.html")
]);

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type !== "prepare-subtitles" || !allowedPrepareSenders.has(sender.url)) return;
  ensureEngine()
    .then(() => reply({ ready: true }))
    .catch(error => reply({ error: error.message }));
  return true;
});

chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status === "loading" && change.url) {
    void chrome.runtime.sendMessage({ type: "source-loading", tabId }).catch(() => {});
  }
});

chrome.tabs.onRemoved.addListener(tabId => {
  void chrome.runtime.sendMessage({ type: "source-closed", tabId }).catch(() => {});
});

chrome.runtime.onMessage.addListener((message, sender) => {
  if (sender.url !== chrome.runtime.getURL(enginePage) || !["watch-subtitles", "stop-subtitles"].includes(message.type)) return;
  void chrome.tabs.sendMessage(message.tabId, { type: message.type }, { frameId: 0 }).catch(() => {});
});
