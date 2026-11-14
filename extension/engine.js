const MODEL_FILENAME = "plamo-3-translate-0.8b-Q4_K_M.gguf";
const MODEL_TEMP_FILENAME = `${MODEL_FILENAME}.part`;
const MODEL_MIN_BYTES = 500 * 1024 * 1024;
const MODEL_DOWNLOAD_URL = "https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF/resolve/main/plamo-3-translate-0.8b-Q4_K_M.gguf";
const modelUrl = chrome.runtime.getURL(`model/${MODEL_FILENAME}`);
const assets = {
  default: "wllama.wasm",
  "wllama.worker.js": "wllama-worker.js",
  "wllama.module.js": "wllama-module.js",
  "wllama.pthread.js": "wllama-pthread.js",
  "wllama.compat.js": "wllama-compat-module.js",
  "wllama.compat.pthread.js": "wllama-compat-pthread.js",
  "wllama.compat.wasm": "wllama-compat.wasm"
};

export const DEFAULT_SERVER_ENDPOINT = "http://127.0.0.1:11434";

let engine;
let activeMode = "auto";
let activeBackend = null;
let degradedReason = "";
let loadingPromise;
let downloadAbortController;
let cachedBlob;
let serverConfig = {
  preset: "ollama",
  endpoint: DEFAULT_SERVER_ENDPOINT,
  model: "",
  apiKey: "",
  usePlamoFormat: false
};

export function getEngineInfo() {
  return { mode: activeMode, backend: activeBackend, degradedReason };
}

export function validateServerEndpoint(rawUrl) {
  const value = String(rawUrl ?? "").trim();
  if (!value) throw new Error("請輸入 LLM Server 的 API 端點網址。");
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error("API 端點網址格式不正確。");
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error("API 端點僅支援 http:// 或 https:// 協定。");
  }
  return parsed.href;
}

export function setServerConfig(nextConfig = {}) {
  serverConfig = {
    preset: String(nextConfig.preset ?? "llama-plamo"),
    endpoint: String(nextConfig.endpoint ?? DEFAULT_SERVER_ENDPOINT).trim() || DEFAULT_SERVER_ENDPOINT,
    model: String(nextConfig.model ?? "").trim(),
    apiKey: String(nextConfig.apiKey ?? "").trim(),
    usePlamoFormat: Boolean(nextConfig.usePlamoFormat)
  };
}

async function readBundledModelBlob() {
  try {
    const response = await fetch(modelUrl);
    if (!response.ok) return null;
    const blob = await response.blob();
    return blob.size >= MODEL_MIN_BYTES ? blob : null;
  } catch {
    return null;
  }
}

async function readOpfsModelFile() {
  if (!navigator.storage?.getDirectory) return null;
  try {
    const root = await navigator.storage.getDirectory();
    const handle = await root.getFileHandle(MODEL_FILENAME);
    const file = await handle.getFile();
    return file.size >= MODEL_MIN_BYTES ? file : null;
  } catch {
    return null;
  }
}

async function downloadModelToOpfs(onProgress) {
  if (!navigator.storage?.getDirectory) {
    throw new Error("目前瀏覽器環境不支援本機快取空間（OPFS），請改用 API 模式。");
  }
  const root = await navigator.storage.getDirectory();
  const controller = new AbortController();
  downloadAbortController = controller;
  let response;
  try {
    response = await fetch(MODEL_DOWNLOAD_URL, { signal: controller.signal });
  } catch (error) {
    if (downloadAbortController === controller) downloadAbortController = undefined;
    if (controller.signal.aborted || error?.name === "AbortError") {
      throw new Error("已取消模型下載。");
    }
    throw new Error("無法連線至 Hugging Face 下載翻譯模型，請檢查網路連線或改用 API 模式。");
  }
  if (!response.ok || !response.body) {
    if (downloadAbortController === controller) downloadAbortController = undefined;
    throw new Error(`下載翻譯模型失敗（HTTP ${response.status}），請稍後重試或改用 API 模式。`);
  }

  const totalBytes = Number(response.headers.get("content-length")) || 0;
  const tempHandle = await root.getFileHandle(MODEL_TEMP_FILENAME, { create: true });
  const writable = await tempHandle.createWritable();
  const reader = response.body.getReader();
  let received = 0;

  try {
    onProgress?.({ phase: "downloading", percent: 0, loadedMB: 0, totalMB: Math.round(totalBytes / 1048576) });
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      await writable.write(value);
      received += value.byteLength;
      const loadedMB = Math.round(received / 1048576);
      const totalMB = Math.round(totalBytes / 1048576);
      const percent = totalBytes > 0 ? Math.min(99, Math.floor((received / totalBytes) * 100)) : null;
      onProgress?.({ phase: "downloading", percent, loadedMB, totalMB });
    }
    await writable.close();
    if (received < MODEL_MIN_BYTES) {
      throw new Error("下載的模型檔案不完整，請重新嘗試。");
    }
    if (typeof tempHandle.move === "function") {
      await tempHandle.move(root, MODEL_FILENAME);
      const finalHandle = await root.getFileHandle(MODEL_FILENAME);
      return await finalHandle.getFile();
    }
    const tempFile = await tempHandle.getFile();
    const finalHandle = await root.getFileHandle(MODEL_FILENAME, { create: true });
    const finalWritable = await finalHandle.createWritable();
    await finalWritable.write(tempFile);
    await finalWritable.close();
    await root.removeEntry(MODEL_TEMP_FILENAME).catch(() => {});
    return await finalHandle.getFile();
  } catch (error) {
    await reader.cancel().catch(() => {});
    await writable.abort().catch(() => {});
    await root.removeEntry(MODEL_TEMP_FILENAME).catch(() => {});
    if (controller.signal.aborted || error?.name === "AbortError") {
      throw new Error("已取消模型下載。");
    }
    throw error;
  } finally {
    if (downloadAbortController === controller) downloadAbortController = undefined;
  }
}

async function getModelBlob(onProgress) {
  if (cachedBlob) return cachedBlob;
  const bundled = await readBundledModelBlob();
  if (bundled) {
    cachedBlob = bundled;
    return cachedBlob;
  }
  const opfsFile = await readOpfsModelFile();
  if (opfsFile) {
    cachedBlob = opfsFile;
    return cachedBlob;
  }
  cachedBlob = await downloadModelToOpfs(onProgress);
  onProgress?.({ phase: "loading" });
  return cachedBlob;
}

async function loadWithBackend(targetBackend, blob) {
  let gpuOffload = false;
  const record = (...parts) => {
    const layers = parts.join(" ").match(/offloaded (\d+)\/(\d+) layers to GPU/);
    if (layers && Number(layers[1]) > 0 && layers[1] === layers[2]) gpuOffload = true;
  };
  const paths = Object.fromEntries(Object.entries(assets).map(([key, name]) =>
    [key, chrome.runtime.getURL("vendor/wllama/" + name)]));

  let Wllama;
  try {
    ({ Wllama } = await import("./vendor/wllama/wllama.js"));
  } catch {
    throw new Error("無法載入本機推論執行環境（vendor/wllama），請確認檔案已放置完整。");
  }

  if (targetBackend === "gpu") {
    const adapter = await navigator.gpu?.requestAdapter();
    if (!adapter || adapter.info.isFallbackAdapter) {
      throw new Error("Chrome 目前無法使用硬體 WebGPU。請檢查 chrome://gpu。");
    }
  }

  const candidate = new Wllama(paths, {
    suppressNativeLog: false,
    logger: { log: record, debug: record, info: record, warn: record, error: console.error }
  });
  try {
    await candidate.loadModel([blob], {
      n_ctx: 2048,
      n_threads: 4,
      n_gpu_layers: targetBackend === "gpu" ? 99 : 0,
      n_parallel: 1
    });
    if (targetBackend === "gpu" && !gpuOffload) {
      throw new Error("模型未完整載入 WebGPU。請檢查 Chrome 硬體加速設定。");
    }
    return candidate;
  } catch (error) {
    await candidate.exit().catch(() => {});
    throw error;
  }
}

export async function unloadEngine() {
  downloadAbortController?.abort();
  if (loadingPromise) {
    await loadingPromise.catch(() => {});
  }
  if (engine) {
    await engine.exit().catch(() => {});
    engine = undefined;
  }
  activeBackend = null;
  degradedReason = "";
}

export async function loadEngine(mode = activeMode, nextServerConfig, onProgress) {
  if (nextServerConfig) setServerConfig(nextServerConfig);
  const normalized = ["auto", "gpu", "cpu", "server"].includes(mode) ? mode : "auto";
  if (normalized === "server") {
    validateServerEndpoint(serverConfig.endpoint);
    downloadAbortController?.abort();
    if (loadingPromise) await loadingPromise.catch(() => {});
    if (engine) {
      await engine.exit().catch(() => {});
      engine = undefined;
    }
    activeMode = "server";
    activeBackend = "server";
    degradedReason = "";
    return { type: "server" };
  }
  if (engine && activeMode === normalized) return engine;
  if (loadingPromise) return loadingPromise;

  loadingPromise = (async () => {
    if (engine) {
      await engine.exit().catch(() => {});
      engine = undefined;
    }
    activeMode = normalized;
    activeBackend = null;
    degradedReason = "";
    const blob = await getModelBlob(onProgress);

    if (normalized === "cpu") {
      engine = await loadWithBackend("cpu", blob);
      activeBackend = "cpu";
      return engine;
    }

    if (normalized === "gpu") {
      engine = await loadWithBackend("gpu", blob);
      activeBackend = "gpu";
      return engine;
    }

    // auto 模式：優先嘗試 GPU，失敗時自動降級為 CPU 並記錄警示原因
    try {
      engine = await loadWithBackend("gpu", blob);
      activeBackend = "gpu";
      return engine;
    } catch (gpuError) {
      engine = await loadWithBackend("cpu", blob);
      activeBackend = "cpu";
      degradedReason = gpuError?.message?.includes("WebGPU")
        ? "硬體 WebGPU 不可用或顯存不足，已自動切換為 CPU 模式（翻譯速度較慢）。"
        : `GPU 推論初始化失敗（${gpuError?.message ?? "未知原因"}），已自動切換為 CPU 模式。`;
      return engine;
    }
  })().finally(() => {
    loadingPromise = undefined;
  });

  return loadingPromise;
}

function sanitizePlamoText(value) {
  return String(value ?? "").replaceAll("<|plamo:", "＜|plamo:");
}

function buildPlamoPrompt(text, { glossary = [], context = "" } = {}) {
  const safeText = sanitizePlamoText(text);
  const safeContext = sanitizePlamoText(context).trim();

  let prompt = "<|plamo:tag|>dataset<|plamo:msg|>translation";
  if (safeContext) {
    prompt += "<|plamo:tag|>context<|plamo:msg|>" + safeContext;
  }
  if (glossary.length) {
    prompt += "<|plamo:tag|>glossary";
    for (const [src, dst] of glossary) {
      prompt += "<|plamo:index|>" + sanitizePlamoText(src) + "<|plamo:item|>" + sanitizePlamoText(dst);
    }
  }
  return prompt + "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>" + safeText +
    "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>zh-hant<|plamo:msg|>";
}

function shouldUsePlamoFormat(config) {
  if (config.preset === "llama-plamo") return true;
  if (config.preset === "custom" && config.usePlamoFormat) return true;
  try {
    const pathname = new URL(config.endpoint).pathname.replace(/\/+$/, "");
    return pathname.endsWith("/completions") && !pathname.endsWith("/chat/completions");
  } catch {
    return false;
  }
}

function resolveEndpoint(rawUrl, plamoFormat) {
  const valid = validateServerEndpoint(rawUrl);
  const parsed = new URL(valid);
  const cleanPath = parsed.pathname.replace(/\/+$/, "");
  if (cleanPath.endsWith("/completions") || cleanPath.endsWith("/chat/completions")) {
    return parsed.href;
  }
  const suffix = plamoFormat ? "/completions" : "/chat/completions";
  parsed.pathname = cleanPath.endsWith("/v1") ? `${cleanPath}${suffix}` : `${cleanPath}/v1${suffix}`;
  return parsed.href;
}

async function requestServerCompletion(payload, config, { maxTokens = 384, timeoutMs = 15000 } = {}) {
  const plamoFormat = shouldUsePlamoFormat(config);
  const endpoint = resolveEndpoint(config.endpoint, plamoFormat);
  const headers = { "Content-Type": "application/json" };
  if (config.apiKey) headers.Authorization = `Bearer ${config.apiKey}`;
  const body = {
    ...payload,
    temperature: payload.temperature ?? 0.1,
    max_tokens: maxTokens,
    stream: false
  };
  if (config.model) body.model = config.model;

  let response;
  try {
    response = await fetch(endpoint, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs)
    });
  } catch (error) {
    if (error?.name === "TimeoutError" || error?.name === "AbortError") {
      throw new Error("LLM Server 回應逾時，請確認伺服器狀態。");
    }
    throw new Error("無法連線至 LLM Server，請確認服務已啟動且網址正確。");
  }

  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    const snippet = detail.trim().slice(0, 80);
    throw new Error(`LLM Server 回傳錯誤 (${response.status})${snippet ? `：${snippet}` : ""}`);
  }

  const data = await response.json().catch(() => null);
  const choice = data?.choices?.[0];
  const content = (choice?.message?.content ?? choice?.text ?? data?.content ?? "").trim();
  if (choice?.finish_reason === "length" && !content) {
    throw new Error("LLM Server 回應超出長度上限。");
  }
  if (!content) throw new Error("LLM Server 未回傳有效的譯文內容。");
  return content;
}

export async function testServerConnection(config) {
  const normalized = {
    preset: String(config?.preset ?? "llama-plamo"),
    endpoint: String(config?.endpoint ?? DEFAULT_SERVER_ENDPOINT).trim() || DEFAULT_SERVER_ENDPOINT,
    model: String(config?.model ?? "").trim(),
    apiKey: String(config?.apiKey ?? "").trim(),
    usePlamoFormat: Boolean(config?.usePlamoFormat)
  };
  const started = performance.now();
  const payload = shouldUsePlamoFormat(normalized)
    ? { prompt: buildPlamoPrompt("こんにちは"), temperature: 0, stop: ["<|plamo:tag|>", "<|plamo:bos|>"] }
    : {
        messages: [
          { role: "system", content: "請將日文翻譯成簡短繁體中文。" },
          { role: "user", content: "こんにちは" }
        ]
      };
  const sample = await requestServerCompletion(payload, normalized, { maxTokens: 24, timeoutMs: 15000 });
  return { ok: true, latencyMs: Math.round(performance.now() - started), sample };
}

async function translateWithServer(text, { glossary = [], context = "", speaker = "" } = {}) {
  if (shouldUsePlamoFormat(serverConfig)) {
    return requestServerCompletion({
      prompt: buildPlamoPrompt(text, { glossary, context }),
      temperature: 0,
      stop: ["<|plamo:tag|>", "<|plamo:bos|>"]
    }, serverConfig);
  }
  const parts = [
    "你是《碧藍幻想》遊戲劇情的日文轉台灣繁體中文專業翻譯員。",
    "請只輸出自然流暢、符合角色語氣的繁體中文譯文，不要附加解釋、標題、引號或日文原文。"
  ];
  if (glossary.length) {
    const terms = glossary.map(([src, dst]) => `${src} → ${dst}`).join("、");
    parts.push(`專有名詞對照（請嚴格遵守）：${terms}`);
  }
  if (context.trim()) {
    parts.push(`前句劇情語境（僅供語氣連貫參考，請勿重複翻譯）：\n${context.trim()}`);
  }
  const userContent = speaker ? `說話者：${speaker}\n${text}` : text;
  return requestServerCompletion({
    messages: [
      { role: "system", content: parts.join("\n\n") },
      { role: "user", content: userContent }
    ]
  }, serverConfig);
}

export async function translate(text, { glossary = [], context = "", speaker = "" } = {}) {
  if (activeMode === "server") {
    return translateWithServer(text, { glossary, context, speaker });
  }
  const runtime = await loadEngine(activeMode);
  const prompt = buildPlamoPrompt(text, { glossary, context });
  const result = await runtime.createCompletion({
    prompt, temperature: 0, max_tokens: 384, stream: false, cache_prompt: false,
    stop: ["<|plamo:tag|>", "<|plamo:bos|>"]
  });
  const translation = (result.content ?? result.choices?.[0]?.text)?.trim();
  if (result.choices?.[0]?.finish_reason === "length") {
    throw new Error("這句台詞的譯文超出長度上限。");
  }
  if (!translation) throw new Error("沒有收到繁中譯文。請重新開啟字幕窗。");
  return translation;
}
