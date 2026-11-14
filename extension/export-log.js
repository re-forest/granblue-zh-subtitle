export function formatHistoryText(entries) {
  return entries.map(entry => {
    const time = entry.time ? `[${entry.time}] ` : "";
    const header = entry.speaker ? `${time}${entry.speaker}` : time.trim();
    const lines = [];
    if (header) lines.push(header);
    lines.push(`繁中：${entry.zh}`);
    if (entry.ja) lines.push(`原文：${entry.ja}`);
    return lines.join("\n");
  }).join("\n\n") + "\n";
}

export function downloadHistoryFile(entries) {
  if (!entries?.length) return false;
  const now = new Date();
  const pad = n => String(n).padStart(2, "0");
  const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}`;
  const blob = new Blob(["\uFEFF" + formatHistoryText(entries)], { type: "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `gbf-subtitles-${stamp}.txt`;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  return true;
}
