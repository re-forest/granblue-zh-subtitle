const WIDTH = 960;
const HEIGHT = 340;
const PAD_X = 44;
const SAFE_TOP = 38;
const SAFE_BOTTOM = 42;
const CONTENT_W = WIDTH - PAD_X * 2;
const FONT_FAMILY = '"Microsoft JhengHei", "PingFang TC", "Noto Sans TC", system-ui, sans-serif';
const NO_LINE_START = new Set("、。，．！？；：」』）】》…—～,.!?;:)]}".split(""));

function drawDiamond(ctx, cx, cy, r) {
  ctx.beginPath();
  ctx.moveTo(cx, cy - r);
  ctx.lineTo(cx + r, cy);
  ctx.lineTo(cx, cy + r);
  ctx.lineTo(cx - r, cy);
  ctx.closePath();
}

function roundRectPath(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, r);
}

function wrapText(ctx, text, maxWidth, maxLines) {
  if (!text) return [];
  const paragraphs = String(text).split(/\r?\n/);
  const lines = [];
  for (const para of paragraphs) {
    if (!para) {
      if (lines.length < maxLines) lines.push("");
      continue;
    }
    let current = "";
    for (const ch of para) {
      const candidate = current + ch;
      if (ctx.measureText(candidate).width <= maxWidth) {
        current = candidate;
      } else if (NO_LINE_START.has(ch) && current.length > 1) {
        lines.push(current.slice(0, -1));
        current = current.slice(-1) + ch;
      } else {
        lines.push(current);
        current = ch;
      }
      if (lines.length >= maxLines) break;
    }
    if (current && lines.length < maxLines) {
      lines.push(current);
    } else if (current && lines.length === maxLines) {
      const last = lines[maxLines - 1];
      let trimmed = last;
      while (trimmed.length > 1 && ctx.measureText(trimmed + "…").width > maxWidth) {
        trimmed = trimmed.slice(0, -1);
      }
      lines[maxLines - 1] = trimmed + "…";
      break;
    }
    if (lines.length >= maxLines) break;
  }
  return lines;
}

export function createPipRenderer(initialSettings = {}) {
  const canvas = document.createElement("canvas");
  canvas.width = WIDTH;
  canvas.height = HEIGHT;
  document.body?.append(canvas);
  const ctx = canvas.getContext("2d", { alpha: false });
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

  const stream = canvas.captureStream(0);
  const [track] = stream.getVideoTracks();

  let settings = {
    fontScale: typeof initialSettings.fontScale === "number" ? initialSettings.fontScale : 1,
    autoFit: typeof initialSettings.autoFit === "boolean" ? initialSettings.autoFit : true
  };
  let currentState = {
    speaker: "",
    caption: "等待劇情台詞…",
    original: "",
    busy: false,
    error: false
  };
  let animTimer;
  let fadeStart = 0;
  let fadeDuration = 0;
  let shimmerStart = 0;

  function drawBackground(now, isBusy) {
    // 深色漸層底色，呼應遊戲對話框視覺
    const bg = ctx.createLinearGradient(0, 0, WIDTH, HEIGHT);
    bg.addColorStop(0, "#071519");
    bg.addColorStop(0.55, "#0d252b");
    bg.addColorStop(1, "#061114");
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, WIDTH, HEIGHT);

    // 星晶青藍光暈（右上）與古銅暖金微光（左下）
    const glowTopRight = ctx.createRadialGradient(WIDTH * 0.86, HEIGHT * 0.14, 10, WIDTH * 0.86, HEIGHT * 0.14, 400);
    glowTopRight.addColorStop(0, "rgba(110, 231, 216, 0.12)");
    glowTopRight.addColorStop(1, "rgba(110, 231, 216, 0)");
    ctx.fillStyle = glowTopRight;
    ctx.fillRect(0, 0, WIDTH, HEIGHT);

    const glowBottomLeft = ctx.createRadialGradient(WIDTH * 0.14, HEIGHT * 0.88, 10, WIDTH * 0.14, HEIGHT * 0.88, 340);
    glowBottomLeft.addColorStop(0, "rgba(212, 180, 117, 0.08)");
    glowBottomLeft.addColorStop(1, "rgba(212, 180, 117, 0)");
    ctx.fillStyle = glowBottomLeft;
    ctx.fillRect(0, 0, WIDTH, HEIGHT);

    // 古銅金雙層飾框（外框較清晰、內框細緻鑲邊）
    ctx.strokeStyle = "rgba(212, 180, 117, 0.38)";
    ctx.lineWidth = 2;
    roundRectPath(ctx, 8, 8, WIDTH - 16, HEIGHT - 16, 16);
    ctx.stroke();

    ctx.strokeStyle = "rgba(212, 180, 117, 0.14)";
    ctx.lineWidth = 1;
    roundRectPath(ctx, 18, 18, WIDTH - 36, HEIGHT - 36, 11);
    ctx.stroke();

    // 四角古銅金框＋星晶青石雙層菱形鉚釘
    for (const [cx, cy] of [[28, 28], [WIDTH - 28, 28], [28, HEIGHT - 28], [WIDTH - 28, HEIGHT - 28]]) {
      ctx.fillStyle = "rgba(212, 180, 117, 0.52)";
      drawDiamond(ctx, cx, cy, 4.4);
      ctx.fill();
      ctx.fillStyle = "#6ee7d8";
      drawDiamond(ctx, cx, cy, 1.9);
      ctx.fill();
    }

    // 翻譯／模型載入等待時：頂部星晶流光細線
    if (isBusy && !reducedMotion.matches) {
      const cycle = ((now - shimmerStart) % 1500) / 1500;
      const barX = 48 + (WIDTH - 96) * cycle;
      const grad = ctx.createLinearGradient(barX - 110, 0, barX + 110, 0);
      grad.addColorStop(0, "rgba(110, 231, 216, 0)");
      grad.addColorStop(0.5, "rgba(212, 180, 117, 0.85)");
      grad.addColorStop(1, "rgba(110, 231, 216, 0)");
      ctx.save();
      roundRectPath(ctx, 48, 17, WIDTH - 96, 3, 2);
      ctx.clip();
      ctx.fillStyle = grad;
      ctx.fillRect(barX - 110, 17, 220, 3);
      ctx.restore();
    }
  }

  function drawFrame(now) {
    const { speaker, caption, original, busy, error } = currentState;
    drawBackground(now, busy);

    let progress = 1;
    if (fadeDuration > 0 && !reducedMotion.matches) {
      progress = Math.min(1, Math.max(0, (now - fadeStart) / fadeDuration));
    }
    const eased = 1 - Math.pow(1 - progress, 3);
    const alpha = fadeDuration > 0 ? 0.25 + 0.75 * eased : 1;
    const offsetY = fadeDuration > 0 ? (1 - eased) * 6 : 0;

    ctx.save();
    ctx.globalAlpha = alpha;

    // 1. 計算主要譯文排版與字級自適應（依使用者設定 fontScale 與 autoFit 調整）
    const scale = Math.min(1.4, Math.max(0.7, settings.fontScale || 1));
    let fontSize = Math.round(50 * scale);
    let lineHeight = Math.round(68 * scale);
    ctx.font = `600 ${fontSize}px ${FONT_FAMILY}`;
    let captionLines = wrapText(ctx, caption || " ", CONTENT_W, settings.autoFit ? 3 : 4);
    if (settings.autoFit && captionLines.length >= 3) {
      fontSize = Math.max(26, Math.round(42 * scale));
      lineHeight = Math.round(fontSize * 1.34);
      ctx.font = `600 ${fontSize}px ${FONT_FAMILY}`;
      captionLines = wrapText(ctx, caption || " ", CONTENT_W, 4);
      if (captionLines.length >= 4) {
        fontSize = Math.max(24, Math.round(35 * scale));
        lineHeight = Math.round(fontSize * 1.32);
        ctx.font = `600 ${fontSize}px ${FONT_FAMILY}`;
        captionLines = wrapText(ctx, caption || " ", CONTENT_W, 4);
      }
    }

    // 2. 計算原文排版（若有）
    const origFontSize = Math.max(20, Math.round(27 * (0.7 + 0.3 * scale)));
    const origLineHeight = Math.round(origFontSize * 1.34);
    let origLines = [];
    if (original) {
      ctx.font = `400 ${origFontSize}px ${FONT_FAMILY}`;
      origLines = wrapText(ctx, original, CONTENT_W, 2);
    }

    const speakerFontSize = Math.max(22, Math.round(28 * (0.7 + 0.3 * scale)));
    const speakerHeight = speaker ? Math.round(speakerFontSize * 1.65) : 0;
    const speakerGap = speaker ? 14 : 0;
    const origGap = origLines.length ? 12 : 0;
    const totalH = speakerHeight + speakerGap + captionLines.length * lineHeight + origGap + origLines.length * origLineHeight;

    const usableTop = SAFE_TOP;
    const usableH = HEIGHT - SAFE_TOP - SAFE_BOTTOM;
    let y = usableTop + Math.max(0, (usableH - totalH) / 2) + offsetY;

    // 3. 繪製角色名稱銘牌（Speaker Pill）
    if (speaker) {
      ctx.font = `600 ${speakerFontSize}px ${FONT_FAMILY}`;
      const textW = ctx.measureText(speaker).width;
      const pillW = Math.min(CONTENT_W, textW + 58);
      const pillH = speakerHeight - 2;
      const pillX = PAD_X;
      const pillY = y;

      ctx.fillStyle = "rgba(14, 38, 44, 0.9)";
      roundRectPath(ctx, pillX, pillY, pillW, pillH, 10);
      ctx.fill();

      ctx.strokeStyle = "rgba(212, 180, 117, 0.56)";
      ctx.lineWidth = 1.4;
      roundRectPath(ctx, pillX, pillY, pillW, pillH, 10);
      ctx.stroke();

      ctx.fillStyle = "#6ee7d8";
      drawDiamond(ctx, pillX + 22, pillY + pillH / 2, 5.5);
      ctx.fill();

      ctx.fillStyle = "#f7efd8";
      ctx.textBaseline = "middle";
      ctx.fillText(speaker, pillX + 38, pillY + pillH / 2 + 1, CONTENT_W - 50);

      y += speakerHeight + speakerGap;
    }

    // 4. 繪製主要繁中譯文
    ctx.font = `600 ${fontSize}px ${FONT_FAMILY}`;
    ctx.textBaseline = "top";
    ctx.shadowColor = "rgba(0, 0, 0, 0.62)";
    ctx.shadowBlur = 8;
    ctx.shadowOffsetY = 2;
    ctx.fillStyle = error ? "#fca5a5" : (busy && !caption ? "#a6c6c8" : "#f7f4eb");
    for (const line of captionLines) {
      ctx.fillText(line, PAD_X, y);
      y += lineHeight;
    }
    ctx.shadowBlur = 0;
    ctx.shadowOffsetY = 0;

    // 5. 繪製日文原文（僅首次載入／錯誤時顯示）
    if (origLines.length) {
      y += origGap;
      ctx.font = `400 ${origFontSize}px ${FONT_FAMILY}`;
      ctx.fillStyle = "#9cb8ac";
      for (const line of origLines) {
        ctx.fillText(line, PAD_X, y);
        y += origLineHeight;
      }
    }

    ctx.restore();
    track?.requestFrame?.();
  }

  function scheduleLoop() {
    clearTimeout(animTimer);
    const now = performance.now();
    drawFrame(now);
    const fading = fadeDuration > 0 && !reducedMotion.matches && (now - fadeStart) < fadeDuration;
    const shimmering = currentState.busy && !reducedMotion.matches;
    if (fading || shimmering) {
      animTimer = setTimeout(scheduleLoop, 16);
    } else {
      fadeDuration = 0;
    }
  }

  function update(nextState, { fade = false } = {}) {
    currentState = { ...currentState, ...nextState };
    const now = performance.now();
    if (fade && !reducedMotion.matches) {
      fadeStart = now;
      fadeDuration = 160;
    } else {
      fadeDuration = 0;
    }
    if (currentState.busy && !shimmerStart) {
      shimmerStart = now;
    } else if (!currentState.busy) {
      shimmerStart = 0;
    }
    scheduleLoop();
  }

  // 先畫出首幀，讓 video.loadedmetadata 立即就緒
  drawFrame(performance.now());

  return {
    stream,
    update,
    setSettings(nextSettings) {
      settings = {
        fontScale: typeof nextSettings?.fontScale === "number" ? nextSettings.fontScale : settings.fontScale,
        autoFit: typeof nextSettings?.autoFit === "boolean" ? nextSettings.autoFit : settings.autoFit
      };
      scheduleLoop();
    },
    dispose() {
      clearTimeout(animTimer);
    }
  };
}
