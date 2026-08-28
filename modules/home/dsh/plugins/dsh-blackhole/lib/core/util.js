// Shared pure text/path helpers for the blackhole subsystems (recall + om).
// These mirror the pi-blackhole vcc core helpers; they are dependency-free so
// the recall and OM adapters can import them without pulling dsh seams.

const ANSI_RE = /\x1b\[[0-9;]*[A-Za-z]/g;
const CTRL_RE = /[\x00-\x08\x0b\x0c\x0e-\x1f]/g;

/** Strip ANSI escapes and control chars; normalize line endings to \n. */
export function sanitize(text) {
  return String(text)
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .replace(ANSI_RE, "")
    .replace(CTRL_RE, "");
}

/** Clip a string to `max` chars at a word boundary, guarding surrogate pairs. */
export function clip(text, max = 200) {
  if (text.length <= max) return text;
  const cut = text.lastIndexOf(" ", max);
  let end = cut > max * 0.6 ? cut : max;
  if (end > 0 && end < text.length) {
    const code = text.charCodeAt(end - 1);
    if (code >= 0xd800 && code <= 0xdbff) end -= 1;
  }
  return text.slice(0, end);
}

/** Clip to `max` chars but prefer to break at a sentence terminator. */
export function clipSentence(text, max = 200) {
  if (text.length <= max) return text;
  const window = text.slice(0, max);
  const matches = [...window.matchAll(/[.!?](?:\s|$)/g)];
  if (matches.length > 0) {
    const last = matches[matches.length - 1];
    const end = (last.index ?? 0) + 1;
    if (end >= max * 0.5) return text.slice(0, end);
  }
  return clip(text, max);
}

/** Split into trimmed non-empty lines. */
export function nonEmptyLines(text) {
  return String(text)
    .split("\n")
    .map(function (line) { return line.trim(); })
    .filter(Boolean);
}

/** First line, clipped. */
export function firstLine(text, max = 200) {
  return clip(String(text).split("\n")[0] ?? "", max);
}

/** Flatten a content-block list into a plain text string. */
export function textOfBlocks(blocks) {
  const parts = [];
  for (const b of blocks || []) {
    if (!b || typeof b !== "object") continue;
    if (b.type === "text") parts.push(b.text || "");
    else if (b.type === "reasoning") parts.push(b.text || "");
    else if (b.type === "tool-result") parts.push(textOfBlocks(b.content));
  }
  return parts.join("\n");
}

/** Candidate key names that carry a file path in tool arguments. */
const PATH_KEYS = ["path", "file_path", "filePath", "file", "filePath"];

export function extractPath(args) {
  for (const key of PATH_KEYS) {
    if (typeof (args || {})[key] === "string") return args[key];
  }
  return null;
}

/** Longest common directory prefix over absolute paths ("/"-joined). */
export function longestCommonDirPrefix(paths) {
  const normalized = paths.map(function (p) { return p.replace(/\\/g, "/"); });
  const abs = normalized.filter(function (p) { return p.startsWith("/") || /^[A-Za-z]:\//.test(p); });
  if (abs.length < 2) return "";
  const split = abs.map(function (p) { return p.split("/"); });
  const min = Math.min.apply(null, split.map(function (s) { return s.length; }));
  let i = 0;
  while (i < min - 1) {
    const seg = split[0][i];
    if (!split.every(function (s) { return s[i] === seg; })) break;
    i += 1;
  }
  if (i < 2) return "";
  return split[0].slice(0, i).join("/") + "/";
}

export function trimPaths(set, prefix) {
  if (!prefix) return set;
  const out = new Set();
  for (const p of set) out.add(p.startsWith(prefix) ? p.slice(prefix.length) : p);
  return out;
}

/** Simple greedy word-wrap into `maxChars`-bounded lines. */
export function wrapText(text, maxChars) {
  if (text.length <= maxChars) return [text];
  const words = text.split(/(\s+)/);
  const lines = [];
  let line = "";
  for (const w of words) {
    if (w.length === 0) continue;
    if (line.length + w.length > maxChars && line.length > 0) {
      lines.push(line.trimEnd());
      line = "";
    }
    line += w;
  }
  if (line) lines.push(line.trimEnd());
  return lines.length > 0 ? lines : [text];
}

export function wrapLongLines(text, maxChars = 120) {
  return String(text)
    .split("\n")
    .flatMap(function (line) {
      const indent = line.match(/^\s*(?:[-*]\s+|\d+\.\s+)?/)?.[0] ?? "";
      const continuation = indent ? " ".repeat(Math.min(indent.length, 8)) : "";
      const safeMax = continuation ? maxChars - continuation.length : maxChars;
      const wrapped = wrapText(line, safeMax);
      if (wrapped.length <= 1 || !continuation) return wrapped;
      return [wrapped[0], ...wrapped.slice(1).map(function (l) { return continuation + l; })];
    })
    .join("\n");
}
