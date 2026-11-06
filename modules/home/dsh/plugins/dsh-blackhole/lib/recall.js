// The `recall` tool — dsh adapter over pi-blackhole's search engine.
//
// dsh owns only the seams: it builds pi Messages from the FULL dsh session
// event log (to-pi.js + Session.snapshotEvents()), renders RenderedEntry[]
// with the package's renderMessage, then delegates search/expand/touched to
// the package's searchEntriesDetailed/getTouchedFiles (bundled in ./core/recall.js).
//
// The event log — not Session.deriveMessages() — is the source of truth here:
// deriveMessages() is the live surface, and a compaction `replace` removes the
// shadowed nodes from it, which would make exactly the material recall exists
// to recover unsearchable. Log seqs are never rewritten, so they also serve as
// the model-facing `#N` handle; the observational-memory ledger records the
// same seqs in `sourceEntryIds`.
//
// Drill-down is re-expressed here because the package's expandEntryFile reads
// pi's session JSONL, not a dsh session; OM id lookup goes through the dsh
// ledger store.

import { searchEntriesDetailed, renderMessage, getTouchedFiles, parseDrillDown } from "./core/recall.js";
import { toPiMessagesFromEvents } from "./to-pi.js";
import { loadLedger } from "./om-store.js";
import {
  recallMemorySources, findObservationsForEntryIds,
  findReflectionsForEntryIds, formatRelatedObservations, MEMORY_ID_PATTERN,
} from "./core/om-core.js";

const PAGE_SIZE = 5;
const DEFAULT_RECENT = 25;
/** Lines a drill-down renders when the query gives no window. */
const DRILLDOWN_PAGE_LINES = 30;
/** Byte cap for a single :full drill-down / the whole response. */
const MAX_FULL_BYTES = 50 * 1024;
const MAX_RESPONSE_CHARS = 48_000;
const name = "recall";
const inject = ["tools", "sessions"];

/** Path-like argument keys across dsh and pi tools. */
const PATH_KEYS = ["path", "file_path", "filePath", "file"];

/**
 * Full-history view. `entries[i].index` is the event seq, not the array
 * position, so `#N` stays valid across compaction.
 */
function buildView(exec) {
  const rows = toPiMessagesFromEvents(exec.agent?.session);
  const piMessages = rows.map((row) => row.message);
  const entries = rows.map((row) => renderMessage(row.message, row.seq, String(row.seq)));
  const posBySeq = new Map(rows.map((row, pos) => [String(row.seq), pos]));
  return { piMessages, entries, posBySeq };
}

// ── response budget ─────────────────────────────────────────────────────────

/** Cap one response so a broad query or many expands cannot flood the context. */
function capResponse(text) {
  if (text.length <= MAX_RESPONSE_CHARS) return text;
  const cut = text.lastIndexOf("\n", MAX_RESPONSE_CHARS);
  const end = cut > MAX_RESPONSE_CHARS * 0.8 ? cut : MAX_RESPONSE_CHARS;
  return `${text.slice(0, end)}\n\n… [response truncated at ${MAX_RESPONSE_CHARS} chars — refine the query, page with :offset:limit, or expand one entry]`;
}

// ── drill-down (#N:text / #N:file / #N:path) ────────────────────────────────

function textOf(content) {
  if (typeof content === "string") return content;
  return (content || [])
    .filter((part) => part?.type === "text")
    .map((part) => part.text ?? "")
    .join("\n");
}

/** File writes/edits carried by one message's tool calls. */
function contentBearingCalls(piMessage) {
  const calls = [];
  for (const part of piMessage?.content || []) {
    if (part?.type !== "toolCall") continue;
    const args = part.arguments;
    if (!args || typeof args !== "object") continue;
    const path = PATH_KEYS.map((key) => args[key]).find((value) => typeof value === "string");
    if (!path) continue;
    const call = { name: part.name ?? "", path };
    if (typeof args.content === "string" && args.content) call.content = args.content;
    else if (typeof args.oldText === "string" || typeof args.newText === "string") {
      call.oldText = typeof args.oldText === "string" ? args.oldText : undefined;
      call.newText = typeof args.newText === "string" ? args.newText : undefined;
    }
    if (call.content === undefined && call.oldText === undefined && call.newText === undefined) continue;
    calls.push(call);
  }
  return calls;
}

function callBody(call) {
  if (call.content) return call.content;
  if (call.oldText !== undefined || call.newText !== undefined) {
    return `--- old ---\n${call.oldText ?? ""}\n--- new ---\n${call.newText ?? ""}`;
  }
  return "(no file content found in tool call arguments)";
}

/** Preview / window / full rendering shared by file and message-text bodies. */
function renderBody(body, label, handle, parsed) {
  const lines = body.split("\n");
  const total = lines.length;

  if (parsed.full) {
    const bytes = Buffer.byteLength(body, "utf8");
    if (bytes > MAX_FULL_BYTES) {
      const truncated = body.slice(0, MAX_FULL_BYTES);
      const shown = truncated.split("\n").length - 1;
      return `${label}\n\n${truncated}\n\n... (${bytes - MAX_FULL_BYTES} more bytes — exceeds 50KB display limit. Use ${handle}:${shown} for the next page.)`;
    }
    return `${label}\n\n${body}`;
  }

  if (parsed.offset !== undefined) {
    const start = Math.max(0, parsed.offset);
    const take = parsed.limit ?? DRILLDOWN_PAGE_LINES;
    const end = Math.min(start + take, total);
    const visible = lines.slice(start, end);
    if (visible.length === 0) {
      return `Offset ${start} is beyond length ${total}. Use ${handle} for the first ${DRILLDOWN_PAGE_LINES} lines.`;
    }
    let out = `${label} — lines ${start + 1}-${end} (of ${total}):\n\n${visible.join("\n")}`;
    if (end < total) {
      out += `\n\n--- Use ${handle}:${end} or ${handle}:${end}:${take} for the next ${take} lines, ${handle}:full for complete ---`;
    } else if (start > 0) {
      out += "\n\n(End)";
    }
    return out;
  }

  if (total > DRILLDOWN_PAGE_LINES) {
    const preview = lines.slice(0, DRILLDOWN_PAGE_LINES).join("\n");
    return `${label}\n\n${preview}\n\n...(${total - DRILLDOWN_PAGE_LINES} more lines — use ${handle}:full for complete content, or ${handle}:${DRILLDOWN_PAGE_LINES} for the next ${DRILLDOWN_PAGE_LINES} lines)`;
  }
  return `${label}\n\n${body}`;
}

function drillFromEntry(piMessage, parsed) {
  const index = parsed.index;
  const body = textOf(piMessage?.content);
  const calls = contentBearingCalls(piMessage);
  const matched = calls.filter((call) => call.path.includes(parsed.pathPattern));

  // #N:text — the entry's own message body, so a clipped expand can be paged.
  // ("text" is also a substring of real paths; message text wins when present.)
  if (parsed.pathPattern === "text") {
    const handle = `#${index}:text`;
    if (body.trim()) {
      let out = renderBody(body, `Entry #${index} message text:`, handle, parsed);
      if (matched.length > 0) {
        out += `\n\n--- Note: entry #${index} also has ${matched.length} file operation(s) matching "text" — use #${index}:file or a more specific path ---`;
      }
      return out;
    }
    if (matched.length === 0) return `Entry #${index} has no message text.`;
  }

  // #N:file — the only file operation, or a list when ambiguous.
  if (parsed.pathPattern === "file") {
    if (calls.length === 0) return `No file content found in entry #${index}.`;
    if (calls.length === 1) return renderCall(calls[0], parsed, `#${index}:file`);
    return ambiguous(index, calls, "file");
  }

  if (matched.length === 0) return `No file content found in entry #${index} for "${parsed.pathPattern}".`;
  if (matched.length > 1) return ambiguous(index, matched, parsed.pathPattern);
  return renderCall(matched[0], parsed, `#${index}:${matched[0].path}`);
}

function renderCall(call, parsed, handle) {
  return renderBody(callBody(call), `File: ${call.path}\nTool: ${call.name}`, handle, parsed);
}

function ambiguous(index, calls, pattern) {
  const items = calls.map((call) => `  [#${index}:${call.path}] ${call.name}(${call.path})`);
  return `Entry #${index} has ${calls.length} file operations matching "${pattern}":\n${items.join("\n")}\n\nUse #${index}:<more-specific-path> to drill into a specific file.`;
}

// ── search / expand rendering ───────────────────────────────────────────────

function formatHits(hits, query, page, totalPages, total, expandedCount, note = "") {
  const body = hits.map((h) => {
    const ref = h.index !== undefined ? ` (#${h.index})` : "";
    const prefix = h.role === "assistant" && h.files ? "* " : "- ";
    const snippet = h.snippet ?? h.summary ?? "";
    const fileNotes = h.fileMatches?.length
      ? ` [files: ${h.fileMatches.map((f) => (typeof f === "object" && f && "path" in f ? f.path : f)).join(", ")}]`
      : "";
    return `${prefix}${snippet}${fileNotes}${ref}`;
  }).join("\n");
  if (!body) return "No matching entries.";
  if (!query) return body;
  const extra = expandedCount > 0 ? ` + ${expandedCount} expanded` : "";
  const header = totalPages > 1
    ? `Page ${page}/${totalPages} (${total} matches${extra}${note})`
    : `${total} matches${extra}${note}`;
  return `${header}\n\n${body}`;
}

/** Render one seq's entry at full fidelity. */
function renderFull(view, seq) {
  const pos = view.posBySeq.get(String(seq));
  if (pos === undefined) return undefined;
  return renderMessage(view.piMessages[pos], Number(seq), String(seq), true);
}

function expandIndices(view, expandSet, exec) {
  const lines = [];
  const found = [];
  for (const idx of expandSet) {
    const entry = renderFull(view, idx);
    if (!entry) { lines.push(`No entry #${idx}.`); continue; }
    found.push(entry);
    lines.push(`#${idx} [${entry.role}]${(entry.files?.length ? ` ${entry.files.join(", ")}` : "")}\n${entry.summary}`);
  }
  let out = lines.join("\n\n");
  // OM coupling: attach related observations/reflections for expanded entries.
  const ledger = loadLedger(exec.agent?.id);
  if (ledger && found.length > 0) {
    const ids = found.map((e) => String(e.id));
    const obs = findObservationsForEntryIds(ledger.observations, ids);
    const refs = findReflectionsForEntryIds(ledger.reflections, ids);
    if (obs.length > 0 || refs.length > 0) out += `\n\n${formatRelatedObservations(obs, refs)}`;
  }
  return out;
}

/** Render an OM id recall with its source entries recovered from the view. */
function renderMemoryRecall(memoryId, result, view) {
  const lines = [];
  if (result.collision) lines.push(`ID ${memoryId} matched multiple items.`);
  for (const r of result.reflections) lines.push(`[${r.id}] ${r.content}`);
  for (const o of result.observations) {
    const dropped = o.status === "dropped" ? " [dropped]" : "";
    lines.push(`[${o.id}]${dropped} ${o.timestamp} [${o.relevance}] ${o.content}`);
  }
  if (result.sourceEntries.length > 0) {
    lines.push("", "Sources:");
    for (const seq of result.sourceEntries) {
      const key = String(seq);
      const pos = view.posBySeq.get(key);
      if (pos === undefined) { lines.push(`#${key} (not in this session's history)`); continue; }
      const entry = renderMessage(view.piMessages[pos], Number(key), key);
      lines.push(`#${key} [${entry.role}] ${entry.summary}`);
    }
  }
  return lines.join("\n") || `Memory ${memoryId} found, but no evidence rendered.`;
}

// ── execute ─────────────────────────────────────────────────────────────────

async function run(args, exec) {
  const view = buildView(exec);
  const { entries, piMessages } = view;
  const q = (args.query ?? "").trim();
  const wantsExpand = Array.isArray(args.expand) && args.expand.length > 0;

  // #N:path drill-down
  if (q) {
    const parsed = parseDrillDown(q);
    if (parsed && parsed.pathPattern) {
      const pos = view.posBySeq.get(String(parsed.index));
      if (pos === undefined) return `No entry #${parsed.index}.`;
      return drillFromEntry(piMessages[pos], parsed);
    }
  }

  // #N expand
  if (q && /^#(\d+)$/.test(q)) {
    const idx = parseInt(q.match(/^#(\d+)$/)[1], 10);
    return expandIndices(view, new Set([idx]), exec);
  }

  // 12-char hex OM id
  if (MEMORY_ID_PATTERN.test(q)) {
    const ledger = loadLedger(exec.agent?.id);
    const result = recallMemorySources(ledger, q);
    if (result.status === "not_found") return `No observation or reflection with id ${q} was found.`;
    if (result.status === "invalid_id") return "Memory id must be 12 lowercase hex characters.";
    return renderMemoryRecall(q, result, view);
  }

  // Touched mode — same shape as pi's formatTouchedOutput (5 per page, tool per
  // entry), without pi's process.cwd()-relative shortening: dsh's cwd is the
  // workspace, not the server process.
  if (args.mode === "touched") {
    const touched = getTouchedFiles(piMessages, entries);
    if (touched.length === 0) return "No file operations found in session history.";
    const page = Math.max(1, args.page ?? 1);
    const start = (page - 1) * PAGE_SIZE;
    const totalPages = Math.ceil(touched.length / PAGE_SIZE);
    const lines = touched
      .slice(start, start + PAGE_SIZE)
      .map((t) => `  ${t.path}    ${t.entries.map((e) => `#${e.index} (${e.toolName})`).join(", ")}`);
    const header = totalPages > 1
      ? `Page ${page}/${totalPages} (${touched.length} total files)`
      : `${touched.length} files touched`;
    let out = `${header}:\n\n${lines.join("\n")}`;
    if (page < totalPages) out += `\n\n--- Use page:${page + 1} for more results ---`;
    return out;
  }

  // No query: either the requested expands, or the most recent entries in one
  // response (matching pi's default view; paging a newest-window would put the
  // OLDEST of that window on page 1).
  if (!q) {
    if (wantsExpand) return expandIndices(view, new Set(args.expand), exec);
    const recent = entries.slice(-DEFAULT_RECENT);
    return formatHits(recent, "", 1, 1, recent.length, 0);
  }

  const page = Math.max(1, args.page ?? 1);
  const mode = args.mode ?? "hybrid";
  const search = searchEntriesDetailed(entries, piMessages, q, undefined, mode);
  let hits = search.hits;
  const truncatedNote = search.truncated
    ? ` — showing ${hits.length} of ${search.totalBeforeCap} matches, refine your query for more precise results`
    : "";
  let expandedCount = 0;

  // query + expand: merge full entries into the search results (pi semantics),
  // replacing truncated summaries and appending non-matching entries.
  if (wantsExpand) {
    const expanded = args.expand.map((seq) => renderFull(view, seq)).filter(Boolean);
    const byIndex = new Map(expanded.map((entry) => [entry.index, entry]));
    const matched = new Set();
    hits = hits.map((hit) => {
      const full = byIndex.get(hit.index);
      if (!full) return hit;
      matched.add(hit.index);
      return { ...hit, summary: full.summary };
    });
    for (const entry of expanded) {
      if (!matched.has(entry.index)) { hits.push(entry); expandedCount += 1; }
    }
    hits.sort((a, b) => a.index - b.index);
  }

  const totalPages = Math.ceil(hits.length / PAGE_SIZE);
  if (hits.length > 0 && page > totalPages) {
    return `Page ${page} is outside the available range 1-${totalPages} (${hits.length} matches). Use a page between 1 and ${totalPages}.`;
  }
  const start = (page - 1) * PAGE_SIZE;
  const pageHits = hits.slice(start, start + PAGE_SIZE);
  // The header reports matches on this page; the window is PAGE_SIZE wide.
  return formatHits(pageHits, q, page, totalPages, hits.length, expandedCount, truncatedNote);
}

async function execute(args, exec) {
  return capResponse(await run(args, exec));
}

function apply(ctx, config) {
  ctx.tools.register({
    name,
    description:
      "Search full session history and file write/edit content by text/regex. " +
      "#N expands an entry; #N:path drills into file content, #N:text into the message body, " +
      "both with optional :offset:limit or :full; 12-char hex ids recover observation/reflection sources; " +
      "mode:file for file-content-only, mode:touched aggregates files-by-path. " +
      "Use this to recover details lost to compaction. " +
      "If a query returns nothing, try fewer terms or a regex pattern. " +
      "When a drill-down path matches multiple files, the options are listed — narrow it with a more specific substring. " +
      "Write and edit payloads are searchable; bash output is only reachable via #N:text.",
    // `parameters` must be a full JSON Schema with an object root. dsh's
    // raw `ctx.tools.register()` does NOT normalize a bare property map (only
    // `defineTool()` does), so without `type: "object"` the model API rejects
    // the tool ("schema must be a JSON Schema of 'type: \"object\"'").
    parameters: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description:
            "Text/regex search; #N expands an entry; #N:path drills file content; #N:text pages the message body; 12-char hex for observations.",
        },
        expand: {
          type: "array",
          items: { type: "number" },
          description: "Entry indices to return full untruncated content for. Standalone or with query.",
        },
        page: { type: "number", description: "Page (1-based) for paginated results." },
        mode: { type: "string", enum: ["hybrid", "file", "touched"], description: "What content to search." },
      },
    },
    output: {
      schema: { type: "string" },
      render: (_args, value) => [{ type: "text", text: String(value ?? "") }],
    },
    execute,
  });
}

export { name, inject, apply, execute as recallExecute };
