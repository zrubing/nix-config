// Core observational-memory (OM) logic — pure, dsh-independent.
//
// The ledger is a plain JSON object kept per-session:
//   {
//     version: 1,
//     observations: [{ id, timestamp, relevance, content, source, sourceEntryIds, status, tokenCount }],
//     reflections:  [{ id, timestamp, content, source, sourceEntryIds, tokenCount }],
//     cursors:      { observer: number, reflector: number, dropper: number },
//     lastErrorAt:  number | undefined,
//     cooldowns:    { "<provider>/<model>": { until, reason } },
//   }
// `id` is a 12-char lowercase hex identifier the `recall` tool resolves back to
// source evidence. Cursors are the index (into the derived-message array) the
// observer last covered, so it only processes NEW content. The dsh adapter owns
// filesystem I/O, the LLM worker calls, and the compaction injection; this
// module owns the shapes, transforms, renderers, and the pure model-candidate /
// chunking / cooldown helpers so the memory layer stays testable without dsh.

import { sanitize, clip } from "./util.js";

export const MEMORY_ID_PATTERN = /^[a-f0-9]{12}$/;

/** Estimate tokens from characters using pi's conservative chars/4 heuristic. */
export function estimateTokens(text) {
  return Math.ceil(String(text || "").length / 4);
}

/** Mint a 12-char lowercase hex id (6 random bytes). */
export function newId(rand = Math.random, cryptoObj = globalThis.crypto) {
  const bytes = new Uint8Array(6);
  if (cryptoObj && typeof cryptoObj.getRandomValues === "function") {
    cryptoObj.getRandomValues(bytes);
  } else {
    for (let i = 0; i < bytes.length; i += 1) bytes[i] = Math.floor(rand() * 256);
  }
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function isValidMemoryId(id) {
  return MEMORY_ID_PATTERN.test(String(id || ""));
}

/** Coerce a possibly-missing/partial parsed ledger into a valid shape. */
export function normalizeLedger(raw) {
  const observations = Array.isArray(raw?.observations) ? raw.observations : [];
  const reflections = Array.isArray(raw?.reflections) ? raw.reflections : [];
  const cursors = raw?.cursors && typeof raw.cursors === "object" ? raw.cursors : {};
  const cooldowns = raw?.cooldowns && typeof raw.cooldowns === "object" ? raw.cooldowns : {};
  return {
    version: 1,
    observations: observations.map((o) => ({
      id: String(o.id || ""),
      timestamp: String(o.timestamp || ""),
      relevance: String(o.relevance || "medium"),
      content: String(o.content || ""),
      source: String(o.source || ""),
      sourceEntryIds: Array.isArray(o.sourceEntryIds) ? o.sourceEntryIds : [],
      status: o.status === "dropped" ? "dropped" : "active",
      tokenCount: Number.isFinite(o.tokenCount) ? o.tokenCount : estimateTokens(o.content || ""),
    })),
    reflections: reflections.map((r) => ({
      id: String(r.id || ""),
      timestamp: String(r.timestamp || ""),
      content: String(r.content || ""),
      source: String(r.source || ""),
      sourceEntryIds: Array.isArray(r.sourceEntryIds) ? r.sourceEntryIds : [],
      tokenCount: Number.isFinite(r.tokenCount) ? r.tokenCount : estimateTokens(r.content || ""),
    })),
    cursors: {
      observer: Number.isFinite(cursors.observer) ? Number(cursors.observer) : -1,
      reflector: Number.isFinite(cursors.reflector) ? Number(cursors.reflector) : -1,
      dropper: Number.isFinite(cursors.dropper) ? Number(cursors.dropper) : -1,
    },
    lastErrorAt: Number.isFinite(raw?.lastErrorAt) ? Number(raw.lastErrorAt) : undefined,
    cooldowns: Object.fromEntries(
      Object.entries(cooldowns)
        .filter(([, v]) => v && typeof v === "object")
        .map(([k, v]) => [k, { until: Number(v.until) || 0, reason: String(v.reason || "") }]),
    ),
  };
}

export function addObservation(ledger, obs) {
  const entry = {
    id: obs.id || newId(),
    timestamp: obs.timestamp || new Date().toISOString().slice(0, 10),
    relevance: obs.relevance || "medium",
    content: sanitize(String(obs.content || "")) || "(empty)",
    source: obs.source || "",
    sourceEntryIds: Array.isArray(obs.sourceEntryIds) ? obs.sourceEntryIds : [],
    status: "active",
    tokenCount: Number.isFinite(obs.tokenCount) ? obs.tokenCount : estimateTokens(obs.content || ""),
  };
  ledger.observations.push(entry);
  return entry;
}

export function addReflection(ledger, refl) {
  const entry = {
    id: refl.id || newId(),
    timestamp: refl.timestamp || new Date().toISOString().slice(0, 10),
    content: sanitize(String(refl.content || "")) || "(empty)",
    source: refl.source || "",
    sourceEntryIds: Array.isArray(refl.sourceEntryIds) ? refl.sourceEntryIds : [],
    tokenCount: Number.isFinite(refl.tokenCount) ? refl.tokenCount : estimateTokens(refl.content || ""),
  };
  ledger.reflections.push(entry);
  return entry;
}

/** True when an observation with the same normalized content already exists. */
export function hasObservationContent(ledger, content) {
  const key = sanitize(String(content || "")).trim().toLowerCase();
  if (!key) return true;
  return ledger.observations.some((o) => sanitize(o.content).trim().toLowerCase() === key);
}

/** Dedup existing observations by content; drop ones that fell below value. */
export function pruneObservations(ledger, poolMax) {
  const seen = new Set();
  const kept = [];
  for (const o of ledger.observations) {
    const key = o.content.trim().toLowerCase();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    kept.push(o);
  }
  const active = kept.filter((o) => o.status === "active");
  const droppedCount = active.length - poolMax;
  const activeKept = active.slice(0, Math.max(0, poolMax));
  const pruned = new Map(activeKept.map((o) => [o.id, "active"]));
  for (const o of kept) {
    if (pruned.has(o.id)) continue;
    if (droppedCount > 0) {
      pruned.set(o.id, "dropped");
      droppedCount -= 1;
    } else {
      pruned.set(o.id, o.status);
    }
  }
  ledger.observations = kept.map((o) => ({ ...o, status: pruned.get(o.id) ?? o.status }));
  return ledger.observations.filter((o) => o.status === "active").length;
}

/** Sum of active observation tokens (the observation pool pressure). */
export function poolTokens(ledger) {
  return ledger.observations
    .filter((o) => o.status !== "dropped")
    .reduce((s, o) => s + (o.tokenCount || estimateTokens(o.content || "")), 0);
}

/**
 * Cap source entries to maxTokens by keeping newest entries first
 * (walk backwards until the token budget is exceeded). `entries` are
 * { index, role, text } records; returns the kept slice in ascending index order.
 */
export function chunkSourceEntries(entries, maxTokens) {
  const kept = [];
  let total = 0;
  for (let i = entries.length - 1; i >= 0; i -= 1) {
    const e = entries[i];
    const tok = estimateTokens(e.text || "");
    if (total + tok > maxTokens && kept.length > 0) break;
    // Always keep the newest entry even if it alone exceeds the budget.
    if (total + tok > maxTokens && kept.length === 0) {
      kept.unshift(e);
      break;
    }
    kept.unshift(e);
    total += tok;
  }
  return kept;
}

// ── model-candidate + cooldown helpers ───────────────────────────────────────

export function modelKey(model) {
  return `${model?.provider ?? ""}/${model?.id ?? ""}`;
}

/** Cooldown expiry for one model key; true means the model is still cooling down. */
export function isCooledDown(cooldowns, key) {
  const entry = cooldowns?.[key];
  if (!entry) return false;
  if ((entry.until || 0) > Date.now()) return true;
  delete cooldowns[key];
  return false;
}

/** Record a cooldown for a model key. cooldownHours 0 keeps it in-memory-only (no entry). */
export function recordCooldownInto(cooldowns, key, reason, cooldownHours = 1) {
  if (!key) return;
  if (cooldownHours === 0) {
    delete cooldowns[key];
    return;
  }
  const ms = (Number.isFinite(cooldownHours) ? cooldownHours : 1) * 3600 * 1000;
  cooldowns[key] = { until: Date.now() + ms, reason: String(reason || "") };
}

/**
 * Build the ordered candidate list for a stage, mirroring pi-blackhole:
 *   stage primary -> stage fallbacks -> base model
 * The session model is the last resort handled by the caller via `sessionFallback`.
 */
export function candidateModels(cfg, worker) {
  const primary =
    worker === "observer" ? cfg.observerModel
    : worker === "reflector" ? cfg.reflectorModel
    : cfg.dropperModel;
  const fallbacks =
    worker === "observer" ? cfg.observerFallbackModels
    : worker === "reflector" ? cfg.reflectorFallbackModels
    : cfg.dropperFallbackModels;
  const list = [];
  if (primary?.provider && primary?.id) list.push(primary);
  for (const fb of fallbacks || []) {
    if (fb?.provider && fb?.id && modelKey(fb) !== modelKey(primary)) list.push(fb);
  }
  if (cfg.model?.provider && cfg.model?.id && !list.some((m) => modelKey(m) === modelKey(cfg.model))) {
    list.push(cfg.model);
  }
  return list;
}

// ── render (the block injected after the vcc compaction summary) ────────────

const OM_PREAMBLE =
  "These are condensed memories from earlier in this session. " +
  "Bracketed ids connect to their source session entries.";

export function renderSummary(reflections, observations) {
  const parts = [];
  const refl = reflections || [];
  const obs = (observations || []).filter((o) => o.status !== "dropped");
  if (refl.length > 0) {
    parts.push("## Reflections");
    for (const r of refl) parts.push(`[${r.id}] ${r.content}`);
  }
  if (obs.length > 0) {
    parts.push("## Observations");
    for (const o of obs) {
      parts.push(`[${o.id}] ${o.timestamp} [${o.relevance}] ${o.content}`);
    }
  }
  if (parts.length > 0) {
    parts.unshift(OM_PREAMBLE);
  }
  parts.push("",
    "Use `recall` with an id to retrieve original context, or `#N:path` drill-down to explore file content from referenced entries.",
    "When entries conflict, the most recent observation reflects the latest known state.",
  );
  return parts.join("\n");
}

// ── reverse-recall (OM coupling for recall #N) ──────────────────────────────

export function findObservationsForEntryIds(observations, entryIds) {
  return (observations || []).filter((o) =>
    (o.sourceEntryIds || []).some((id) => entryIds.includes(id)),
  );
}

export function findReflectionsForEntryIds(reflections, entryIds) {
  return (reflections || []).filter((r) =>
    (r.sourceEntryIds || []).some((id) => entryIds.includes(id)),
  );
}

export function formatRelatedObservations(obs, refs) {
  const lines = [];
  if ((refs || []).length > 0) {
    lines.push("Related reflections:");
    for (const r of refs) lines.push(`- [${r.id}] ${clip(r.content, 200)}`);
  }
  if ((obs || []).length > 0) {
    lines.push("Related observations:");
    for (const o of obs) lines.push(`- [${o.id}] ${clip(o.content, 200)}`);
  }
  return lines.join("\n");
}

/** Resolve a 12-hex id to its observation/reflection source records. */
export function recallMemorySources(ledger, memoryId) {
  if (!isValidMemoryId(memoryId)) {
    return { status: "invalid_id", memoryId, observations: [], reflections: [], sourceEntries: [] };
  }
  const observations = ledger.observations.filter((o) => o.id === memoryId);
  const reflections = ledger.reflections.filter((r) => r.id === memoryId);
  const collision = observations.length + reflections.length > 1;
  if (observations.length === 0 && reflections.length === 0) {
    return { status: "not_found", memoryId, observations: [], reflections: [], sourceEntries: [] };
  }
  const sourceEntries = [];
  const seen = new Set();
  for (const o of observations) {
    for (const id of o.sourceEntryIds || []) if (!seen.has(id)) { seen.add(id); sourceEntries.push(id); }
  }
  for (const r of reflections) {
    for (const id of r.sourceEntryIds || []) if (!seen.has(id)) { seen.add(id); sourceEntries.push(id); }
  }
  return { status: "found", memoryId, collision, observations, reflections, sourceEntries };
}

export function renderMemorySources(ledger, memoryId, result) {
  const lines = [];
  if (result.collision) lines.push(`ID ${memoryId} matched multiple items.`);
  for (const r of result.reflections) lines.push(`[${r.id}] ${r.content}`);
  for (const o of result.observations) {
    const dropped = o.status === "dropped" ? " [dropped]" : "";
    lines.push(`[${o.id}]${dropped} ${o.timestamp} [${o.relevance}] ${o.content}`);
  }
  if (result.sourceEntries.length > 0) {
    lines.push("", "Sources:");
    for (const id of result.sourceEntries) lines.push(`- source entry ${id}`);
  }
  return lines.join("\n") || `Memory ${memoryId} found, but no evidence rendered.`;
}

// ── worker prompts (single-shot LLM calls, chunked by the adapter) ──────────

export const OBSERVER_PROMPT = [
  "You extract durable, timestamped observations from a coding session.",
  "Read the conversation and output a JSON array of observations.",
  "Each observation: {\"content\": string, \"relevance\": \"high\"|\"medium\"|\"low\", \"source\": string}",
  "Capture facts, decisions, user preferences, and explicit requirements.",
  "Do NOT invent details not present in the conversation.",
  "Output ONLY the JSON array.",
].join("\n");

export const REFLECTOR_PROMPT = [
  "You distill durable reflections from observations about a coding session.",
  "Read the observations and output a JSON array of reflections.",
  "Each reflection: {\"content\": string, \"source\": string}",
  "Reflections are stable facts, patterns, or constraints that survive future compactions.",
  "Do NOT invent details; only synthesize from the observations.",
  "Output ONLY the JSON array.",
].join("\n");

export const DROPPER_PROMPT = [
  "You prune low-value observations from a coding-session memory pool.",
  "Read the observations; keep the most valuable entries and drop redundant or trivial ones.",
  "Output a JSON array of the kept observations (same shape as input).",
  "Output ONLY the JSON array.",
].join("\n");

export { sanitize, clip };
