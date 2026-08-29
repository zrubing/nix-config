// The `recall` tool — dsh adapter over pi-blackhole's search engine.
//
// dsh owns only the seams: it builds pi Messages from the live dsh Session
// (to-pi.js + Session.deriveMessages()), renders RenderedEntry[] with the
// package's renderMessage, then delegates search/expand/touched to the
// package's searchEntries/getTouchedFiles (bundled in ./core/recall.js).
// Drill-down (#N:path) is re-expressed here because the package's expandEntryFile
// reads pi's session JSONL, not a dsh session; OM id lookup goes through the
// dsh ledger store.

import { searchEntries, renderMessage, getTouchedFiles, parseDrillDown } from "./core/recall.js";
import { toPiMessages } from "./to-pi.js";
import { loadLedger } from "./om-store.js";
import {
  recallMemorySources, renderMemorySources, findObservationsForEntryIds,
  findReflectionsForEntryIds, formatRelatedObservations, MEMORY_ID_PATTERN,
} from "./core/om-core.js";

const PAGE_SIZE = 5;
const DEFAULT_RECENT = 25;
const name = "recall";
const inject = ["tools", "sessions"];

function sessionMessages(exec) {
  return exec.agent?.session?.deriveMessages?.() ?? [];
}

function buildView(exec) {
  const piMessages = toPiMessages(sessionMessages(exec));
  const entries = piMessages.map((m, i) => renderMessage(m, i, String(m.id ?? i)));
  return { piMessages, entries };
}

function fileContentFromMessage(piMessage, pathPattern) {
  const blocks = piMessage?.content;
  if (typeof blocks === "string") return null;
  let selected = null;
  for (const part of blocks || []) {
    if (part?.type !== "toolCall") continue;
    const args = part.arguments;
    if (typeof args !== "object" || args === null) continue;
    if (args.command !== "create") continue;
    const content = typeof args.content === "string" ? args.content : "";
    const path = args.file_path ?? args.path ?? "";
    if (pathPattern && !path.includes(pathPattern)) continue;
    selected = { path: String(path), lines: content.split("\n") };
  }
  return selected;
}

function renderFileRange(lines, start, end) {
  const out = [];
  for (let i = start; i < end && i < lines.length; i += 1) out.push(`${i + 1}: ${lines[i]}`);
  return out.join("\n");
}

function drillFromEntry(piMessage, parsed) {
  const file = fileContentFromMessage(piMessage, parsed.pathPattern);
  if (!file) return `Entry #${parsed.index} did not write indexable file content.`;
  const lines = file.lines;
  const start = parsed.offset !== undefined ? parsed.offset
    : parsed.pathPattern ? Math.max(0, lines.findIndex((l) => l.includes(parsed.pathPattern))) || 0 : 0;
  const end = parsed.full ? lines.length
    : (parsed.limit !== undefined ? start + parsed.limit : Math.min(lines.length, start + 30));
  return renderFileRange(lines, start, end);
}

function formatHits(hits, query, page, totalPages) {
  const body = hits.map((h) => {
    const ref = h.index !== undefined ? ` (#${h.index})` : "";
    const prefix = h.role === "assistant" && h.files ? "* " : "- ";
    const snippet = h.snippet ?? h.summary ?? "";
    const fileNotes = h.fileMatches?.length
      ? ` [files: ${h.fileMatches.map((f) => (typeof f === "object" && f && "path" in f ? f.path : f)).join(", ")}]`
      : "";
    return `${prefix}${snippet}${fileNotes}${ref}`;
  }).join("\n");
  const header = query
    ? (totalPages > 1 ? `Page ${page}/${totalPages} (${hits.length} matches)` : `${hits.length} matches`)
    : "";
  return body ? (header ? `${header}\n\n${body}` : body) : "No matching entries.";
}

function expandIndices(entries, expandSet, exec) {
  const lines = [];
  for (const idx of expandSet) {
    const e = entries[idx];
    if (!e) { lines.push(`No entry #${idx}.`); continue; }
    lines.push(`#${idx} [${e.role}]${(e.files?.length ? ` ${e.files.join(", ")}` : "")}\n${e.summary}`);
  }
  let out = lines.join("\n\n");
  // OM coupling: attach related observations/reflections for expanded entries.
  const ledger = loadLedger(exec.agent?.id);
  if (ledger && expandSet.size > 0) {
    const ids = [...expandSet].map((i) => String(entries[i]?.id ?? i)).filter(Boolean);
    const obs = findObservationsForEntryIds(ledger.observations, ids);
    const refs = findReflectionsForEntryIds(ledger.reflections, ids);
    if (obs.length > 0 || refs.length > 0) out += `\n\n${formatRelatedObservations(obs, refs)}`;
  }
  return out;
}

async function execute(args, exec) {
  const { piMessages, entries } = buildView(exec);
  const q = (args.query ?? "").trim();

  // #N:path drill-down
  if (q) {
    const parsed = parseDrillDown(q);
    if (parsed && parsed.pathPattern) {
      const piMessage = piMessages[parsed.index];
      if (!piMessage) return `No entry #${parsed.index}.`;
      return drillFromEntry(piMessage, parsed);
    }
  }

  // #N expand
  if (q && /^#(\d+)$/.test(q)) {
    const idx = parseInt(q.match(/^#(\d+)$/)[1], 10);
    return expandIndices(entries, new Set([idx]), exec);
  }

  // 12-char hex OM id
  if (MEMORY_ID_PATTERN.test(q)) {
    const ledger = loadLedger(exec.agent?.id);
    const result = recallMemorySources(ledger, q);
    if (result.status === "not_found") return `No observation or reflection with id ${q} was found.`;
    if (result.status === "invalid_id") return `Memory id must be 12 lowercase hex characters.`;
    return renderMemorySources(ledger, q, result);
  }

  // Multi-entry expand via `expand` param
  if (args.expand && args.expand.length > 0) {
    return expandIndices(entries, new Set(args.expand), exec);
  }

  // Touched mode
  if (args.mode === "touched") {
    const touched = getTouchedFiles(piMessages, entries);
    const page = Math.max(1, args.page ?? 1);
    const start = (page - 1) * PAGE_SIZE;
    const slice = touched.slice(start, start + PAGE_SIZE);
    const totalPages = Math.ceil(touched.length / PAGE_SIZE);
    const lines = slice.map((t) => `- ${t.path} — ${t.entries.map((e) => `#${e.index}`).join(", ")}`);
    const header = totalPages > 1 ? `Touched files (page ${page}/${totalPages})` : `Touched files (${touched.length})`;
    return [header, ...(lines.length ? lines : ["(none reported)"])].join("\n");
  }

  const page = Math.max(1, args.page ?? 1);
  const mode = args.mode ?? "hybrid";
  const hits = searchEntries(entries, piMessages, q, page, mode);
  const totalPages = Math.ceil(hits.length / PAGE_SIZE);
  const start = (page - 1) * PAGE_SIZE;
  const pageHits = hits.slice(start, start + PAGE_SIZE);
  return formatHits(pageHits, q, page, totalPages);
}

function apply(ctx, config) {
  ctx.tools.register({
    name,
    description:
      "Search session history and file write/edit content by text/regex. " +
      "#N expands an entry; #N:path drills into file content with optional :offset:limit or :full; " +
      "12-char hex ids recover observation/reflection sources; mode:file for file-content-only, " +
      "mode:touched aggregates files-by-path. Use this to recover details lost to compaction.",
    // `parameters` must be a full JSON Schema with an object root. dsh's
    // raw `ctx.tools.register()` does NOT normalize a bare property map (only
    // `defineTool()` does), so without `type: "object"` the model API rejects
    // the tool ("schema must be a JSON Schema of 'type: "object"'").
    parameters: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description:
            "Text/regex search; #N expands an entry; #N:path drills file content; 12-char hex for observations.",
        },
        expand: {
          type: "array",
          items: { type: "number" },
          description: "Entry indices to return full untruncated content for.",
        },
        page: { type: "number", description: "Page (1-based) for paginated results." },
        scope: { type: "string", enum: ["lineage", "all"], description: "Search scope (default lineage = whole session)." },
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
