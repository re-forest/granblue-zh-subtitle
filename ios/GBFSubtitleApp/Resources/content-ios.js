// 唯讀擷取遊戲對話框文字並透過 WKScriptMessageHandler 回報給原生 SwiftUI 字幕艙
(() => {
  if (window.__gbfSubtitleBridgeInstalled) return;
  window.__gbfSubtitleBridgeInstalled = true;

  const dungeonEventSelector = "#js-prt-dungeon-temporary-choices.active";

  function readChoices() {
    const choices = document.querySelectorAll(
      ".cnt-quest-scene .prt-sel-area .prt-sel-inner .btn-select-balloon, " +
      `${dungeonEventSelector} img[src*="/arcarum3/dungeon_choice/btn_choice.png"] + div`
    );
    const visibleChoices = Array.from(choices)
      .filter(choice => {
        if (!choice || typeof choice.getClientRects !== "function" || !choice.getClientRects().length) {
          return false;
        }
        return typeof getComputedStyle === "function"
          ? getComputedStyle(choice).visibility === "visible"
          : true;
      })
      .map(choice => (choice.innerText ?? choice.textContent ?? "").trim().replace(/\s*\n\s*/g, " "))
      .filter(Boolean);
    return visibleChoices.map((text, index) => `${index + 1}. ${text}`).join("\n");
  }

  function readDungeonDialogue() {
    const message = document.querySelector(
      `${dungeonEventSelector} img[src*="/arcarum3/dungeon_choice/base_comment.png"] + div`
    );
    if (!message || typeof message.getClientRects !== "function" || !message.getClientRects().length) {
      return "";
    }
    return (message.innerText ?? message.textContent ?? "").trim();
  }

  function readDialogue() {
    const choices = readChoices();
    if (choices) {
      return { speaker: "", text: choices };
    }

    const dungeonText = readDungeonDialogue();
    if (dungeonText) {
      return { speaker: "", text: dungeonText };
    }

    const boxes = document.querySelectorAll(".prt-scene-comment");
    for (let i = boxes.length - 1; i >= 0; i--) {
      const box = boxes[i];
      const message = box.querySelector(".txt-message");
      if (!message || typeof message.getClientRects !== "function" || !message.getClientRects().length) {
        continue;
      }
      const rawText = (message.innerText ?? message.textContent ?? "").trim();
      if (!rawText) continue;
      const speakerEl = box.querySelector(".txt-character-name");
      const rawSpeaker = speakerEl ? (speakerEl.innerText ?? speakerEl.textContent ?? "").trim() : "";
      return {
        speaker: rawSpeaker,
        text: rawText
      };
    }
    return { speaker: "", text: "" };
  }

  let observer = null;
  let previous = null;
  let checkTimer = null;
  let active = true;

  function postToNative(payload) {
    try {
      const handler = window.webkit?.messageHandlers?.subtitleBridge;
      if (handler && typeof handler.postMessage === "function") {
        handler.postMessage(payload);
      }
    } catch {
      // 忽略橋接尚未就緒或頁面正在卸載時的例外
    }
  }

  function publishDialogue() {
    if (!active) return;
    const next = readDialogue();
    if (previous && next.speaker === previous.speaker && next.text === previous.text) {
      return;
    }
    previous = next;
    postToNative({
      type: "subtitle-line",
      speaker: next.speaker,
      text: next.text,
      href: String(location.href || "")
    });
  }

  function scheduleCheck() {
    if (!active) return;
    publishDialogue();
    if (checkTimer !== null) {
      clearTimeout(checkTimer);
    }
    // 針對遊戲淡入或文字框展開動畫延遲檢查，避免剛切換時版面尚未就緒而漏抓
    checkTimer = setTimeout(() => {
      checkTimer = null;
      publishDialogue();
    }, 120);
  }

  function startWatching() {
    active = true;
    if (observer || !document.body) return;
    observer = new MutationObserver(scheduleCheck);
    observer.observe(document.body, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true,
      attributeFilter: ["class", "style", "hidden"]
    });
    window.addEventListener("hashchange", scheduleCheck);
    window.addEventListener("popstate", scheduleCheck);
    scheduleCheck();
  }

  function stopWatching() {
    active = false;
    if (checkTimer !== null) {
      clearTimeout(checkTimer);
      checkTimer = null;
    }
    if (observer) {
      observer.disconnect();
      observer = null;
    }
    previous = null;
    window.removeEventListener("hashchange", scheduleCheck);
    window.removeEventListener("popstate", scheduleCheck);
  }

  function forceCheck() {
    previous = null;
    if (!observer) {
      startWatching();
    } else {
      scheduleCheck();
    }
  }

  window.__gbfSubtitleBridge = {
    forceCheck,
    startWatching,
    stopWatching,
    readDialogue
  };

  function init() {
    postToNative({
      type: "subtitle-source-ready",
      href: String(location.href || "")
    });
    startWatching();
  }

  window.addEventListener("pageshow", event => {
    if (event.persisted) {
      previous = null;
      init();
    }
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init, { once: true });
  } else {
    init();
  }
})();
