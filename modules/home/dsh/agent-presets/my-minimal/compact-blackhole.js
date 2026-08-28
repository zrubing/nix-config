// pi-blackhole deterministic compaction — dsh adapter
//
// Ported from pi-blackhole 0.4.3 (k0valik). STATIC SNAPSHOT: dsh cannot load pi
// extensions and pi-blackhole is not a dsh dependency, so this file embeds the
// upstream deterministic compile() pipeline version-pinned at 0.4.3. Tracking a
// pi-blackhole update is a MANUAL re-port (copy src/core/summarize.ts + extract/*
// + core/brief.ts + core/format.ts, re-apply the dsh normalize() adapter, rebuild).
// The dsh-facing import (@deepseek-ai/dsh-compaction-basic) is pinned by flake.lock
// and is the only coupling the dsh seam exposes; the summarize() subclass hook is
// stable, so a dsh upgrade does not break this plugin.
//
// dsh already has a compaction seam: ctx.compaction is an abstract
// CompactionEngine and dsh-compaction-basic is the default LLM backend. Its README
// declares summarize() as the sole subclass hook, so this adapter subclasses
// BasicCompactionEngine and overrides ONLY summarize(), replacing the LLM stream
// call with the deterministic compile(). Pressure, /compact, <compacted-summary>
// framing and the tool-result pruner stay as dsh ships them.
//
// Two adaptations for dsh:
//   * normalize() maps dsh Message/ContentBlock shape to pi-vcc NormalizedBlock.
//   * File-activity/noise tool-name sets use the dsh vocabulary (str_replace_editor
//     with view/create/str_replace/insert, bash) instead of pi's Read/Edit/Write.
// The TUI word-wrap helper is replaced with a self-contained plain-text wrapper.

import { BasicCompactionEngine } from "@deepseek-ai/dsh-compaction-basic";

const name = "blackhole-compact";
const inject = ["llm", "tokenMeter", "sessions"];
const Config = BasicCompactionEngine.Config;

// ── content helpers ─────────────────────────────────────────────────────────

const ANSI_RE = /\x1b\[[0-9;]*[A-Za-z]/g;
const CTRL_RE = /[\x00-\x08\x0b\x0c\x0e-\x1f]/g;

function sanitize(text) {
  return String(text)
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .replace(ANSI_RE, "")
    .replace(CTRL_RE, "");
}

function clip(text, max = 200) {
  if (text.length <= max) return text;
  const cut = text.lastIndexOf(" ", max);
  let end = cut > max * 0.6 ? cut : max;
  if (end > 0 && end < text.length) {
    const code = text.charCodeAt(end - 1);
    if (code >= 0xd800 && code <= 0xdbff) end -= 1;
  }
  return text.slice(0, end);
}

function clipSentence(text, max = 200) {
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

function nonEmptyLines(text) {
  return String(text)
    .split("\n")
    .map(function (line) { return line.trim(); })
    .filter(Boolean);
}

function firstLine(text, max = 200) {
  return clip(String(text).split("\n")[0] ?? "", max);
}

function textOfBlocks(blocks) {
  const parts = [];
  for (const b of blocks || []) {
    if (!b || typeof b !== "object") continue;
    if (b.type === "text") parts.push(b.text || "");
    else if (b.type === "reasoning") parts.push(b.text || "");
    else if (b.type === "tool-result") parts.push(textOfBlocks(b.content));
  }
  return parts.join("\n");
}

// ── tool-args ───────────────────────────────────────────────────────────────

const PATH_KEYS = ["path", "file_path", "filePath", "file"];

function extractPath(args) {
  for (const key of PATH_KEYS) {
    if (typeof (args || {})[key] === "string") return args[key];
  }
  return null;
}

// ── skill collapse ──────────────────────────────────────────────────────────

const SKILL_TAG_RE = /^-?\s*<skill\s+name="([^"]+)"/;
const SKILL_CLOSE_RE = /^-?\s*<\/skill>/;

function collapseSkillLines(lines) {
  const result = [];
  const seenSkills = new Set();
  let insideSkill = false;
  for (const line of lines) {
    const skillMatch = line.match(SKILL_TAG_RE);
    if (skillMatch) {
      insideSkill = true;
      if (!seenSkills.has(skillMatch[1])) {
        seenSkills.add(skillMatch[1]);
        result.push("[skill: " + skillMatch[1] + "]");
      }
      continue;
    }
    if (insideSkill) {
      if (SKILL_CLOSE_RE.test(line)) insideSkill = false;
      continue;
    }
    result.push(line);
  }
  return result;
}

const SKILL_BLOCK_RE = /<skill\s+name="([^"]+)"[^>]*>[\s\S]*?(?:<\/skill>|$)/g;
function collapseSkillText(text) {
  return String(text).replace(SKILL_BLOCK_RE, function (_m, n) {
    return "[skill: " + n + "]";
  });
}

// ── normalize (dsh Message/ContentBlock -> pi-vcc NormalizedBlock) ──────────

function cleanCheckpoint(text) {
  return String(text)
    .replace(/<compacted-summary>[\s\S]*?<\/compacted-summary>/g, "")
    .replace(/This is an automatically generated checkpoint condensing an earlier span of the conversation to free up context\.[\s\S]*?without acknowledging this checkpoint\./g, "")
    .trim();
}

function normalize(messages) {
  const callNames = new Map();
  for (const msg of messages || []) {
    if (msg?.role !== "assistant") continue;
    for (const part of msg.content || []) {
      if (part?.type === "tool-call") callNames.set(part.id, part.name);
    }
  }
  const out = [];
  for (let i = 0; i < (messages || []).length; i += 1) {
    out.push(...normalizeOne(messages[i], i, callNames));
  }
  return out;
}

function normalizeOne(msg, idx, callNames) {
  const role = msg?.role;
  if (role === "user") {
    const blocks = [];
    const textParts = [];
    for (const part of msg.content || []) {
      if (part.type === "text") {
        const t = cleanCheckpoint(sanitize(part.text || ""));
        if (t) textParts.push(t);
      } else if (part.type === "tool-result") {
        const toolName = callNames.get(part.toolCallId) || "unknown";
        const text = sanitize(textOfBlocks(part.content));
        blocks.push({ kind: "tool_result", name: toolName, text, isError: !!part.isError, sourceIndex: idx });
      } else if (part.type === "image") {
        blocks.push({ kind: "user", text: "[image]", sourceIndex: idx });
      }
    }
    if (textParts.length > 0) {
      blocks.push({ kind: "user", text: textParts.join("\n"), sourceIndex: idx });
    }
    if (blocks.length === 0) blocks.push({ kind: "user", text: "", sourceIndex: idx });
    return blocks;
  }
  if (role === "assistant") {
    const blocks = [];
    for (const part of msg.content || []) {
      if (part.type === "text") {
        blocks.push({ kind: "assistant", text: sanitize(part.text || ""), sourceIndex: idx });
      } else if (part.type === "reasoning") {
        blocks.push({ kind: "thinking", text: sanitize(part.text || ""), redacted: false, sourceIndex: idx });
      } else if (part.type === "tool-call") {
        let args = {};
        try { args = JSON.parse(part.arguments || "{}") || {}; } catch (_e) { args = {}; }
        blocks.push({ kind: "tool_call", name: part.name, args, sourceIndex: idx });
      }
    }
    return blocks;
  }
  return [];
}

// ── filter-noise ────────────────────────────────────────────────────────────

const NOISE_TOOLS = new Set([
  "TodoWrite", "TodoRead", "ToolSearch", "AskUser",
  "ExitSpecMode", "GenerateDroid", "tool-todo",
]);

const NOISE_STRINGS = [
  "Continue from where you left off.",
  "No response requested.",
  "IMPORTANT: TodoWrite was not called yet.",
];

const XML_WRAPPER_RE = /<(system-reminder|ide_opened_file|command-message|context-window-usage)[^>]*>[\s\S]*?<\/\1>/g;

function cleanOrNull(text) {
  const trimmed = String(text).trim();
  if (NOISE_STRINGS.some(function (s) { return trimmed.includes(s); })) return null;
  const cleaned = trimmed.replace(XML_WRAPPER_RE, "").trim();
  return cleaned.length > 0 ? cleaned : null;
}

function filterNoise(blocks) {
  const out = [];
  for (const b of blocks) {
    if (b.kind === "thinking") continue;
    if (b.kind === "tool_call" && NOISE_TOOLS.has(b.name)) continue;
    if (b.kind === "tool_result" && NOISE_TOOLS.has(b.name)) continue;
    if (b.kind === "user") {
      const cleaned = cleanOrNull(b.text);
      if (!cleaned) continue;
      out.push({ ...b, text: cleaned });
      continue;
    }
    out.push(b);
  }
  return out;
}

// ── extract/goals ───────────────────────────────────────────────────────────

const SCOPE_CHANGE_RE = /\b(instead|actually|change of plan|forget that|new task|switch to|now I want|pivot|let'?s do|stop .* and)\b/i;
const TASK_RE = /\b(fix|implement|add|create|build|refactor|debug|investigate|update|remove|delete|migrate|deploy|test|write|set up)\b/i;
const NOISE_SHORT_RE = /^(ok|yes|no|sure|yeah|yep|go|hi|hey|thx|thanks|ok\b.*|y|n|k)\s*[.!?]*$/i;
const NON_GOAL_RE = /^\s*[\[│├└─╭╰]|\x60\x60\x60|^\s*(=[A-Z]+\(|function |const |let |var |import |export |class )|^(https?:|file:|\/[A-Za-z])|\\n|^\s*For each\b|\bin full\b[^\n]*\b(comments|issue|issues|PRs?|linked)\b/;
const TEMPLATE_SIGNAL_RE = /^\s*(For each\b|Do NOT implement\b|Analyze and propose\b|If Task\/context\b|Output:\s*$)/i;
const MAX_GOAL_CHARS = 200;
const FIRST_MSG_CLIP = 80;
const LEADING_CHARS = 200;

function truncateAtTemplate(lines) {
  const idx = lines.findIndex(function (l) { return TEMPLATE_SIGNAL_RE.test(l); });
  return idx >= 0 ? lines.slice(0, idx) : lines;
}

function stripLeadingBullet(line) {
  return line.replace(/^\s*(?:[-*+]|\d+\.)\s+/, "").trim();
}

function isSubstantiveGoal(text) {
  const t = String(text).trim();
  if (t.length <= 5) return false;
  if (t.length > MAX_GOAL_CHARS) return false;
  if (NOISE_SHORT_RE.test(t)) return false;
  if (NON_GOAL_RE.test(t)) return false;
  return true;
}

function indexSuffix(sourceIndex) {
  return sourceIndex != null ? " (#" + sourceIndex + ")" : "";
}

function extractGoals(blocks) {
  const goals = [];
  let latestScopeChange = null;
  let latestScopeIndex;
  for (const b of blocks) {
    if (b.kind !== "user") continue;
    const rawLines = nonEmptyLines(b.text);
    const truncated = truncateAtTemplate(rawLines);
    const lines = collapseSkillLines(truncated.filter(isSubstantiveGoal))
      .map(stripLeadingBullet)
      .filter(function (l) { return l.length > 5; });
    if (lines.length === 0) continue;
    if (goals.length === 0) {
      goals.push(...lines.slice(0, 6).map(function (l) { return clip(l, FIRST_MSG_CLIP) + indexSuffix(b.sourceIndex); }));
      continue;
    }
    const leading = b.text.slice(0, LEADING_CHARS);
    if (SCOPE_CHANGE_RE.test(leading)) {
      latestScopeChange = lines.slice(0, 3).map(function (l) { return clip(l, MAX_GOAL_CHARS); });
      latestScopeIndex = b.sourceIndex;
    } else if (TASK_RE.test(leading) && lines[0].length > 15) {
      latestScopeChange = lines.slice(0, 2).map(function (l) { return clip(l, MAX_GOAL_CHARS); });
      latestScopeIndex = b.sourceIndex;
    }
  }
  if (latestScopeChange && latestScopeChange.length > 0) {
    goals.push("[Scope change]");
    for (const line of latestScopeChange) {
      goals.push(line + indexSuffix(latestScopeIndex));
    }
  }
  return goals.slice(0, 8);
}

// ── extract/files (dsh tool vocabulary) ─────────────────────────────────────

const FILE_READ_TOOLS = new Set(["Read", "read_file", "View"]);
const FILE_WRITE_TOOLS = new Set(["Edit", "Write", "edit", "write", "edit_file", "write_file", "MultiEdit"]);

function longestCommonDirPrefix(paths) {
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

function trimPaths(set, prefix) {
  if (!prefix) return set;
  const out = new Set();
  for (const p of set) out.add(p.startsWith(prefix) ? p.slice(prefix.length) : p);
  return out;
}

function classifyEditorCall(b) {
  const cmd = typeof b.args.command === "string" ? b.args.command : "";
  if (cmd === "view") return "read";
  if (cmd === "create") return "created";
  if (cmd === "str_replace" || cmd === "insert") return "modified";
  return null;
}

function extractFiles(blocks) {
  const act = { read: new Set(), modified: new Set(), created: new Set() };
  for (const b of blocks) {
    if (b.kind !== "tool_call") continue;
    const p = extractPath(b.args);
    if (!p) continue;
    const cls = b.name === "str_replace_editor" ? classifyEditorCall(b) : null;
    if (cls === "read" || FILE_READ_TOOLS.has(b.name)) act.read.add(p);
    if (cls === "modified" || FILE_WRITE_TOOLS.has(b.name)) act.modified.add(p);
    if (cls === "created") act.created.add(p);
  }
  const all = [...act.read, ...act.modified, ...act.created];
  const prefix = longestCommonDirPrefix(all);
  if (prefix) {
    act.read = trimPaths(act.read, prefix);
    act.modified = trimPaths(act.modified, prefix);
    act.created = trimPaths(act.created, prefix);
  }
  return act;
}

// ── extract/commits (bash git commit) ───────────────────────────────────────

const COMMIT_MSG_RE = /git\s+commit[^\n]*?-m\s+(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|\$?'((?:[^'\\]|\\.)*)')/;
const HASH_RE = /\b([0-9a-f]{8,12})\b/;

function firstLineOf(text) {
  const line = String(text).split(/\\n|\n/)[0] ?? "";
  return line.trim();
}

function cleanMessage(msg) {
  return msg.replace(/\\"/g, '"').replace(/\\'/g, "'").trim();
}

function extractHashFromOutput(text) {
  const bracket = text.match(/\[\S+\s+([0-9a-f]{7,12})\]/);
  if (bracket) return bracket[1];
  const range = text.match(/\b([0-9a-f]{7,12})\.\.([0-9a-f]{7,12})\b/);
  if (range) return range[2];
  const plain = text.match(HASH_RE);
  if (plain) return plain[1];
  return undefined;
}

function tryExtractMessage(cmd) {
  if (!/\bgit\s+commit\b/.test(cmd)) return undefined;
  const m = cmd.match(COMMIT_MSG_RE);
  if (!m) return undefined;
  const message = firstLineOf(cleanMessage(m[1] ?? m[2] ?? m[3] ?? ""));
  return message || undefined;
}

function extractCommits(blocks) {
  const commits = [];
  const addCommit = function (hash, message) {
    const key = (hash ?? "") + "::" + message;
    if (!commits.some(function (c) { return (c.hash ?? "") + "::" + c.message === key; })) {
      commits.push({ hash: hash, message: message });
    }
  };
  for (let i = 0; i < blocks.length; i += 1) {
    const b = blocks[i];
    if (b.kind === "tool_call" && b.name === "bash") {
      const cmd = b.args && typeof b.args.command === "string" ? b.args.command : "";
      const message = tryExtractMessage(cmd);
      if (!message) continue;
      let hash;
      for (let j = i + 1; j < Math.min(blocks.length, i + 3); j += 1) {
        const r = blocks[j];
        if (r.kind !== "tool_result") continue;
        hash = extractHashFromOutput(r.text);
        if (hash) break;
      }
      addCommit(hash, message);
      continue;
    }
    // pi's user-wrapped bash execution (Ran <cmd> block) is not emitted by dsh:
    // bash output arrives as a tool_result, so that case is not ported.
  }
  return commits;
}

function formatCommits(commits, limit = 8) {
  const lines = [];
  const items = commits.slice(-limit);
  for (const c of items) {
    const prefix = c.hash ? c.hash + ": " : "";
    lines.push(prefix + c.message);
  }
  return lines;
}

// ── extract/preferences ─────────────────────────────────────────────────────

const PREF_PATTERNS = [
  /\bprefer(?:s|red|ring)?\s+\w/i,
  /\bdon'?t want\b/i,
  /\balways (?:use|do|run|prefer|keep|make|format|write|add|set|put|prefix|start|include|append)\b/i,
  /\bnever (?:use|do|run|push|commit|write|ignore|add|set|put|remove|delete|include|deploy)\b/i,
  /\bplease (?:use|avoid|keep|make|don'?t|do not|format|write)\b/i,
  /\b(?:style|format|language|naming)\s*[:=]\s*\S/i,
];

function extractPreferences(blocks) {
  const prefs = [];
  const seen = new Set();
  for (const b of blocks) {
    if (b.kind !== "user") continue;
    let perBlock = 0;
    for (const line of nonEmptyLines(b.text)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.length < 5) continue;
      if (trimmed.length > 200) continue;
      if (trimmed.endsWith("?") || trimmed.includes("?...")) continue;
      if (!PREF_PATTERNS.some(function (p) { return p.test(trimmed); })) continue;
      const clipped = clip(trimmed, 200);
      const key = clipped.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      prefs.push(clipped);
      perBlock += 1;
      if (perBlock >= 1) break;
    }
  }
  return prefs.slice(0, 10);
}

function dedupPreferencesAgainstGoals(prefs, goals) {
  const norm = function (s) { return String(s).trim().toLowerCase(); };
  const goalSet = new Set(goals.map(norm));
  return prefs.filter(function (p) { return !goalSet.has(norm(p)); });
}

// ── outstanding context ─────────────────────────────────────────────────────

const BLOCKER_RE = /\b(fail(ed|s|ure|ing)?|broken|cannot|can't|won't work|does not work|doesn't work|still (broken|failing|wrong)|blocked|blocker|not (fixed|resolved|working)|crash(es|ed|ing)?)\b/i;

function extractOutstandingContext(blocks) {
  const items = [];
  const tail = blocks.slice(-20);
  for (const b of tail) {
    if (b.kind === "tool_result" && b.isError) {
      items.push("[" + b.name + "] " + firstLine(b.text, 150));
      continue;
    }
    if (b.kind === "assistant" || b.kind === "user") {
      for (const line of nonEmptyLines(b.text)) {
        if (!BLOCKER_RE.test(line)) continue;
        if (line.length < 15) continue;
        if (/^\s*[-*+>]\s/.test(line)) continue;
        if (/^\s*\(/.test(line)) continue;
        if (!/^\s*["'*_]?[A-Z]/.test(line)) continue;
        const clipped = b.kind === "user" ? "[user] " + clipSentence(line, 150) : clipSentence(line, 150);
        if (!items.includes(clipped)) items.push(clipped);
        break;
      }
    }
  }
  return items.slice(0, 5);
}

// ── brief transcript ────────────────────────────────────────────────────────

const TRUNCATE_USER = 256;
const TRUNCATE_ASSISTANT = 200;
const SELF_TALK_PREFIX_RE = /^\s*(?:hmm|wait|actually|oh|okay|ok|well|so)[,.!\s-]+/i;

let _segmenter = undefined;
function wordSegments(text) {
  if (_segmenter) return Array.from(_segmenter.segment(text));
  if (_segmenter === null) {
    const parts = [];
    let idx = 0;
    for (const part of text.split(/(\s+)/)) {
      if (!part) continue;
      parts.push({ segment: part, index: idx, isWordLike: /\S/.test(part) });
      idx += part.length;
    }
    return parts;
  }
  try {
    _segmenter = new Intl.Segmenter(undefined, { granularity: "word" });
    return Array.from(_segmenter.segment(text));
  } catch (_e) {
    _segmenter = null;
    const parts = [];
    let idx = 0;
    for (const part of text.split(/(\s+)/)) {
      if (!part) continue;
      parts.push({ segment: part, index: idx, isWordLike: /\S/.test(part) });
      idx += part.length;
    }
    return parts;
  }
}

const STOP_WORDS = new Set([
  "a","an","the","is","are","was","were","be","been","being","have","has","had",
  "do","does","did","will","would","could","should","may","might","shall","can",
  "need","must","to","of","in","for","on","with","at","by","from","as","into",
  "through","during","before","after","above","below","between","under","over",
  "and","but","or","nor","not","so","yet","both","either","neither","each","every",
  "all","any","few","more","most","other","some","such","no","that","this","these",
  "those","it","its","i","me","my","we","our","you","your","he","him","his","she",
  "her","they","them","their","who","which","what","if","then","than","when","where",
  "how","just","also",
]);

function truncateTokens(text, limit) {
  const flat = text.replace(/\s+/g, " ").trim();
  let count = 0;
  let lastEnd = 0;
  for (const seg of wordSegments(flat)) {
    const isWord = !!seg.isWordLike || /[\p{L}\p{N}]/u.test(seg.segment);
    if (isWord) {
      if (!STOP_WORDS.has(seg.segment.toLowerCase())) {
        count += 1;
        if (count > limit) {
          return flat.slice(0, lastEnd).trimEnd() + "...(truncated)";
        }
      }
    }
    lastEnd = seg.index + seg.segment.length;
  }
  return flat;
}

const BASH_CAP = 120;
const PIPE_TAIL_RE = /\s*\|\s*(?:head|tail|sort|wc|column|tr|cut|uniq)(?:\s[^|]*)?$/;

function compressBash(raw) {
  let cmd = String(raw).split("\n").map(function (l) { return l.trim(); }).filter(Boolean).join("; ");
  cmd = cmd.replace(/^cd\s+\S+\s*&&\s*/, "");
  for (let i = 0; i < 10; i += 1) {
    const stripped = cmd.replace(PIPE_TAIL_RE, "");
    if (stripped === cmd) break;
    cmd = stripped;
  }
  if (cmd.length > BASH_CAP) {
    const cut = cmd.lastIndexOf(" ", BASH_CAP - 2);
    const end = cut > BASH_CAP * 0.6 ? cut : BASH_CAP - 3;
    return cmd.slice(0, end).trimEnd() + "...";
  }
  return cmd;
}

const TOOL_SUMMARY_FIELDS = {
  str_replace_editor: "path",
  Read: "file_path", Edit: "file_path", Write: "file_path",
  read: "path", edit: "path", write: "path",
  Glob: "pattern", Grep: "pattern",
};

function toolOneLiner(name, args) {
  const field = TOOL_SUMMARY_FIELDS[name];
  if (field && typeof args[field] === "string") return "* " + name + ' "' + args[field] + '"';
  const path = extractPath(args);
  if (path) return "* " + name + ' "' + path + '"';
  if (name === "bash" || name === "Bash") {
    const raw = (args.command ?? args.description ?? "");
    return "* " + name + ' "' + compressBash(raw) + '"';
  }
  if (typeof args.query === "string") return "* " + name + ' "' + clip(args.query, 60) + '"';
  return "* " + name;
}

function buildBriefSections(blocks) {
  const sections = [];
  let lastHeader = "";
  const push = function (header, line) {
    if (header === lastHeader && sections.length > 0) {
      sections[sections.length - 1].lines.push(line);
      return;
    }
    sections.push({ header: header, lines: [line] });
    lastHeader = header;
  };
  for (const b of blocks) {
    switch (b.kind) {
      case "user": {
        if (!b.text.trim()) break;
        const text = truncateTokens(collapseSkillText(b.text), TRUNCATE_USER);
        if (text) {
          const ref = b.sourceIndex != null ? " (#" + b.sourceIndex + ")" : "";
          push("[user]", text + ref);
        }
        lastHeader = "[user]";
        break;
      }
      case "bash": {
        const cmd = compressBash(b.command);
        const ref = b.sourceIndex != null ? " (#" + b.sourceIndex + ")" : "";
        if (cmd) push("[user]", "$ " + cmd + ref);
        lastHeader = "[user]";
        break;
      }
      case "assistant": {
        let raw = b.text;
        for (let i = 0; i < 2; i += 1) {
          const stripped = raw.replace(SELF_TALK_PREFIX_RE, "");
          if (stripped === raw) break;
          raw = stripped;
        }
        const text = truncateTokens(raw, TRUNCATE_ASSISTANT);
        if (text) {
          const ref = b.sourceIndex != null ? " (#" + b.sourceIndex + ")" : "";
          push("[assistant]", text + ref);
        }
        break;
      }
      case "tool_call": {
        if (!b.name || b.name.trim() === "") break;
        const ref = b.sourceIndex != null ? " (#" + b.sourceIndex + ")" : "";
        push("[assistant]", toolOneLiner(b.name, b.args) + ref);
        break;
      }
      case "tool_result": {
        if (b.isError) {
          const body = firstLine(b.text, 150);
          if (!body || body === "(no output)") break;
          const ref = b.sourceIndex != null ? " (#" + b.sourceIndex + ")" : "";
          push("[tool_error] " + b.name + ref, body);
          lastHeader = "[tool_error] " + b.name + ref;
        }
        break;
      }
      case "thinking":
        break;
    }
  }
  // Collapse consecutive identical tool lines (same text, different ref).
  for (const sec of sections) {
    if (sec.header !== "[assistant]") continue;
    const out = [];
    for (const line of sec.lines) {
      if (!line.startsWith("* ")) { out.push(line); continue; }
      const ref = line.match(/\(#(\d+)\)$/)?.[1] ?? "";
      const base = ref ? line.slice(0, -(ref.length + 3)).trimEnd() : line;
      const last = out.length > 0 ? out[out.length - 1] : "";
      const m = last.match(/^(.*) \(#[\d, #]+\) x(\d+)$/);
      if (m && m[1] === base) {
        out[out.length - 1] = base + " (#" + ref + ") x" + (parseInt(m[2]) + 1);
      } else if (last.match(/\(#\d+\)$/) && last.replace(/\s*\(#\d+\)$/, "") === base) {
        const prevRef = last.match(/\(#(\d+)\)$/)?.[1];
        out[out.length - 1] = base + " (#" + prevRef + ", #" + ref + ") x2";
      } else {
        out.push(line);
      }
    }
    sec.lines = out;
  }
  // Cap tool calls per turn — keep the tail (edits/writes).
  const TOOL_CALLS_PER_TURN = 8;
  for (const sec of sections) {
    if (sec.header !== "[assistant]") continue;
    const toolIdxs = sec.lines.map(function (l, i) { return l.startsWith("* ") ? i : -1; }).filter(function (i) { return i >= 0; });
    if (toolIdxs.length <= TOOL_CALLS_PER_TURN) continue;
    const dropCount = toolIdxs.length - TOOL_CALLS_PER_TURN;
    const dropSet = new Set(toolIdxs.slice(0, dropCount));
    const firstKeptToolIdx = toolIdxs[dropCount];
    const next = [];
    let inserted = false;
    for (let i = 0; i < sec.lines.length; i += 1) {
      if (dropSet.has(i)) continue;
      if (!inserted && i === firstKeptToolIdx) {
        next.push("* (" + dropCount + " earlier tool-call entries omitted)");
        inserted = true;
      }
      next.push(sec.lines[i]);
    }
    sec.lines = next;
  }
  // Collapse consecutive identical [tool_error] sections.
  const collapsedErrors = [];
  for (const sec of sections) {
    const m = sec.header.match(/^\[tool_error\]\s+(\S+?)(?:\s*\(#(\d+)\))?$/);
    if (!m || sec.lines.length !== 1) { collapsedErrors.push(sec); continue; }
    const tool = m[1];
    const ref = m[2];
    const body = sec.lines[0];
    const prev = collapsedErrors[collapsedErrors.length - 1];
    const prevMatch = prev && prev.header.match(/^\[tool_error\]\s+(\S+?)\s*\(((?:#\d+(?:,\s*)?)+)\)(?:\s*x(\d+))?$/);
    if (prev && prevMatch && prevMatch[1] === tool && prev.lines.length === 1 && prev.lines[0] === body) {
      const refs = prevMatch[2] + (ref ? ", #" + ref : "");
      const count = prevMatch[3] ? parseInt(prevMatch[3]) + 1 : 2;
      prev.header = "[tool_error] " + tool + " (" + refs + ") x" + count;
    } else {
      collapsedErrors.push(sec);
    }
  }
  sections.length = 0;
  sections.push(...collapsedErrors);
  return sections;
}

function stringifyBrief(sections) {
  const out = [];
  for (let i = 0; i < sections.length; i += 1) {
    const sec = sections[i];
    if (i > 0) {
      const prev = sections[i - 1];
      const prevIsToolLike = (prev.header === "[assistant]" && prev.lines.every(function (l) { return l.startsWith("* "); })) || prev.header.startsWith("[tool_error]");
      const curIsToolLike = (sec.header === "[assistant]" && sec.lines.every(function (l) { return l.startsWith("* "); })) || sec.header.startsWith("[tool_error]");
      if (!(prevIsToolLike && curIsToolLike)) out.push("");
    }
    out.push(sec.header);
    for (const line of sec.lines) out.push(line);
  }
  return out.join("\n");
}

// ── build sections ──────────────────────────────────────────────────────────

function formatFileActivity(blocks) {
  const act = extractFiles(blocks);
  for (const p of act.modified) act.created.delete(p);
  const lines = [];
  const cap = function (set, limit) {
    const arr = [...set];
    if (arr.length <= limit) return arr.join(", ");
    return arr.slice(0, limit).join(", ") + " (+" + (arr.length - limit) + " more)";
  };
  if (act.modified.size > 0) lines.push("Modified: " + cap(act.modified, 10));
  if (act.created.size > 0) lines.push("Created: " + cap(act.created, 10));
  if (act.read.size > 0) lines.push("Read: " + cap(act.read, 10));
  return lines;
}

function buildSections(input) {
  const blocks = input.blocks;
  const sessionGoal = extractGoals(blocks);
  const userPreferences = dedupPreferencesAgainstGoals(extractPreferences(blocks), sessionGoal);
  return {
    sessionGoal: sessionGoal,
    outstandingContext: extractOutstandingContext(blocks),
    filesAndChanges: formatFileActivity(blocks),
    commits: formatCommits(extractCommits(blocks)),
    userPreferences: userPreferences,
    briefTranscript: stringifyBrief(buildBriefSections(blocks)),
  };
}

// ── format (self-contained wrap) ────────────────────────────────────────────

const BRIEF_MAX_LINES = 120;
const TUI_SAFE_LINE_CHARS = 120;

function wrapText(text, maxChars) {
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

function wrapLineWithContinuation(line, maxChars) {
  const indent = line.match(/^\s*(?:[-*]\s+|\d+\.\s+)?/)?.[0] ?? "";
  const continuationIndent = indent ? " ".repeat(Math.min(indent.length, 8)) : "";
  const safeMaxChars = continuationIndent ? maxChars - continuationIndent.length : maxChars;
  const wrapped = wrapText(line, safeMaxChars);
  if (wrapped.length <= 1 || !continuationIndent) return wrapped;
  return [wrapped[0], ...wrapped.slice(1).map(function (l) { return continuationIndent + l; })];
}

function wrapLongLines(text, maxChars = TUI_SAFE_LINE_CHARS) {
  return String(text).split("\n").flatMap(function (line) { return wrapLineWithContinuation(line, maxChars); }).join("\n");
}

function capBrief(text) {
  const lines = text.split("\n");
  if (lines.length <= BRIEF_MAX_LINES) return text;
  const kept = lines.slice(-BRIEF_MAX_LINES);
  let firstHeader = kept.findIndex(function (l) { return /^\[.+\]/.test(l); });
  if (firstHeader < 0) {
    const anyAnchor = kept.findIndex(function (l) { return /^\[[^\]]+\]/.test(l); });
    if (anyAnchor > 0) firstHeader = anyAnchor;
  }
  const clean = firstHeader > 0 ? kept.slice(firstHeader) : kept;
  const omitted = lines.length - clean.length;
  return "...(" + omitted + " earlier lines omitted)\n\n" + clean.join("\n");
}

function section(title, items) {
  if (items.length === 0) return "";
  const body = items.map(function (i) { return "- " + i; }).join("\n");
  return "[" + title + "]\n" + body;
}

function formatSummary(data) {
  const headerParts = [
    section("Session Goal", data.sessionGoal),
    section("Files And Changes", data.filesAndChanges),
    section("Commits", data.commits),
    section("Outstanding Context", data.outstandingContext),
    section("User Preferences", data.userPreferences),
  ].filter(Boolean);
  const parts = [];
  if (headerParts.length > 0) parts.push(headerParts.join("\n\n"));
  if (data.briefTranscript) parts.push(capBrief(data.briefTranscript));
  if (parts.length === 0) return "";
  return wrapLongLines(parts.join("\n\n---\n\n"));
}

// ── deterministic compile ───────────────────────────────────────────────────

function compileDeterministic(messages) {
  const blocks = filterNoise(normalize(messages));
  const data = buildSections({ blocks: blocks });
  const fresh = formatSummary(data);
  if (!fresh) return "";
  return wrapLongLines(fresh);
}

// ── engine subclass: override ONLY summarize() ──────────────────────────────

class BlackholeCompactionEngine extends BasicCompactionEngine {
  async summarize(input, agent, signal) {
    if (signal) signal.throwIfAborted();
    const summary = compileDeterministic(input.messages);
    if (!summary || !summary.trim()) {
      throw new Error("deterministic compaction produced no summary content");
    }
    return {
      summary: [{ type: "text", text: summary }],
      provider: "pi-blackhole",
      model: "deterministic-vcc",
    };
  }
}

function apply(ctx, config) {
  ctx.plugin(BlackholeCompactionEngine, config);
}

export { name, inject, Config, apply, BlackholeCompactionEngine, compileDeterministic };
