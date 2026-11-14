function readDungeonDialogue() {
  const message = document.querySelector(
    '#js-prt-dungeon-temporary-choices.active img[src*="/arcarum3/dungeon_choice/base_comment.png"] + div'
  );
  return message?.getClientRects().length ? message.innerText.trim() : "";
}

function readDialogue() {
  const dungeonText = readDungeonDialogue();
  if (dungeonText) return { speaker: "", text: dungeonText };

  const boxes = document.querySelectorAll(".prt-scene-comment");
  for (let i = boxes.length - 1; i >= 0; i--) {
    const box = boxes[i];
    const message = box.querySelector(".txt-message");
    if (!message?.getClientRects().length) continue;
    const text = message.innerText.trim();
    if (!text) continue;
    return {
      speaker: box.querySelector(".txt-character-name")?.innerText.trim() ?? "",
      text
    };
  }
  return { speaker: "", text: "" };
}

let observer;
let previous;
let checkTimer;

function stopWatching() {
  clearTimeout(checkTimer);
  observer?.disconnect();
  observer = undefined;
  previous = undefined;
  window.removeEventListener("hashchange", scheduleCheck);
  window.removeEventListener("popstate", scheduleCheck);
}

function sendSafe(payload) {
  if (!chrome.runtime?.id) {
    stopWatching();
    return Promise.resolve();
  }
  try {
    return chrome.runtime.sendMessage(payload).catch(() => {});
  } catch {
    stopWatching();
    return Promise.resolve();
  }
}

function publishDialogue() {
  if (!chrome.runtime?.id) {
    stopWatching();
    return;
  }
  const next = readDialogue();
  if (next.speaker === previous?.speaker && next.text === previous?.text) return;
  previous = next;
  void sendSafe({ type: "subtitle-line", ...next });
}

function scheduleCheck() {
  publishDialogue();
  clearTimeout(checkTimer);
  // 針對遊戲淡入或文字框展開動畫延遲一個短檢查，避免剛切換時 getClientRects 為 0 漏抓
  checkTimer = setTimeout(publishDialogue, 120);
}

function watch() {
  if (observer) return;
  observer = new MutationObserver(scheduleCheck);
  observer.observe(document.body, {
    subtree: true, childList: true, characterData: true, attributes: true,
    attributeFilter: ["class", "style", "hidden"]
  });
  window.addEventListener("hashchange", scheduleCheck);
  window.addEventListener("popstate", scheduleCheck);
  scheduleCheck();
}

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id !== chrome.runtime.id) return;
  if (message.type === "subtitle-source-status") reply({ available: true });
  if (message.type === "watch-subtitles") {
    previous = undefined;
    watch();
    scheduleCheck();
  }
  if (message.type === "stop-subtitles") {
    stopWatching();
  }
});

function announceSource() {
  void sendSafe({ type: "subtitle-source-ready" })
    .then(state => {
      if (!state?.enabled) return;
      previous = undefined;
      watch();
      scheduleCheck();
    });
}

window.addEventListener("pageshow", event => {
  if (event.persisted) announceSource();
});
announceSource();
