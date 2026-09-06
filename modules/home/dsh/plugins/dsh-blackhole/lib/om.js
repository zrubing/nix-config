// Observational-memory workers — dsh adapter.
//
// Mirrors pi-blackhole's background observer/reflector/dropper trio, but runs
// the LLM calls over dsh's `ctx.llm` (pi's agentLoop cannot load in dsh). This
// differs from pi in two documented ways:
//   1. Each worker is a SINGLE-SHOT structured call (chunked down by token
//      budget), not a multi-turn agentLoop. The observer still works a long
//      chunk in one call; only the newest-first window is capped to
//      observerChunkMaxTokens.
//   2. Cursors are tracked as the index into `Session.deriveMessages()` that
//      the observer last covered, so it only processes NEW content. Combined
//      with content-dedup, this avoids re-observing the same material.
//
// Stage cadence is token-gated (observeAfterTokens / reflectAfterTokens /
// pool pressure), model resolution walks the fallback chain with persisted
// cooldown + a 30s retry gate, and a failure never blocks or breaks the
// conversation — matching pi's "graceful degradation". In auto mode the
// memory lands in the ledger immediately (so the next compaction injects it);
// in manual mode it accumulates in the pending file and only `/blackhole`
// flushes it into the ledger.

import { loadConfig, loadLedger, saveLedger, loadPending, savePending, flushPending, activeCandidateModels, cooldownModel } from "./om-store.js";
import {
  addObservation, addReflection, pruneObservations, estimateTokens,
  chunkSourceEntries, hasObservationContent, poolTokens, newId, sanitize,
  OBSERVER_PROMPT, REFLECTOR_PROMPT, DROPPER_PROMPT,
} from "./core/om-core.js";
import { textOfBlocks, clip } from "./core/util.js";

const name = "blackhole-om";
const inject = ["sessions", "llm"];

/** Grace period between failed consolidation runs (matches pi). */
const RETRY_GATE_MS = 30_000;
/** Hard cap on the observer input we send in one call (defensive). */
const MAX_OBSERVER_INPUT_CHARS = 200_000;

function isManual(cfg) { return cfg.compaction === "manual"; }
function isOff(cfg) { return cfg.compaction === "off"; }

function storeFor(sessionId, cfg) {
  return isManual(cfg) ? loadPending(sessionId) : loadLedger(sessionId);
}

function persist(sessionId, cfg, store) {
  if (isManual(cfg)) savePending(sessionId, store);
  else saveLedger(sessionId, store);
}

/** The session model, when resolvable, as a last-resort worker model. */
function sessionModelOf(ctx) {
  try {
    const sel = ctx.get?.("agentDefaultModel")?.currentSelection?.();
    if (!sel) return undefined;
    const provider = sel?.provider;
    const id = sel?.model ?? sel?.modelId ?? sel?.id;
    if (provider && id) return { provider, id, thinking: sel?.thinking ?? "low" };
  } catch { /* unavailable -> skip session fallback */ }
  return undefined;
}

/** Collect text-bearing conversation entries (user + assistant) w/ their index. */
function collectSourceEntries(agent) {
  const messages = agent?.session?.deriveMessages?.() ?? [];
  const entries = [];
  messages.forEach((msg, index) => {
    if (!msg || msg.role === "system") return;
    let text = "";
    if (msg.role === "user") {
      const blocks = msg.content || [];
      if (blocks.every((p) => p?.type === "tool-result")) return;
      text = textOfBlocks(blocks.filter((p) => p?.type !== "tool-result"));
    } else {
      text = textOfBlocks(msg.content);
    }
    if (!text) return;
    entries.push({ index, role: msg.role === "user" ? "user" : "assistant", text });
  });
  return entries;
}

/** Structured single-shot LLM call -> text (concatenate text deltas). */
async function callLlmText(ctx, model, system, userText, signal) {
  const stream = ctx.llm.stream({
    provider: model.provider,
    model: model.id,
    system,
    signal,
    maxTokens: 2048,
    messages: [{ role: "user", content: [{ type: "text", text: userText }] }],
  });
  let out = "";
  for await (const chunk of stream) {
    if (chunk.type === "text-delta") out += chunk.text;
    else if (chunk.type === "block-end" && chunk.block?.type === "text") out += chunk.block.text ?? "";
    else if (chunk.type === "finish") break;
  }
  return out.trim();
}

/** Heuristically pull a JSON array out of an LLM reply. */
function extractJsonArray(text) {
  if (!text) return [];
  const start = text.indexOf("[");
  const end = text.lastIndexOf("]");
  if (start < 0 || end <= start) return [];
  try {
    const parsed = JSON.parse(text.slice(start, end + 1));
    return Array.isArray(parsed) ? parsed : [];
  } catch { return []; }
}

/**
 * Run one worker stage through the fallback chain (stage model -> stage
 * fallbacks -> base model -> session model), stopping at the first success.
 * Each failure records a cooldown so the failed model is skipped next run.
 */
async function runWorkerStage(ctx, store, cfg, worker, prompt, input, signal) {
  const cooldowns = store.cooldowns;
  const candidates = activeCandidateModels(worker, cfg, cooldowns);
  let lastError;
  for (const model of candidates) {
    try {
      const reply = await callLlmText(ctx, model, prompt, input, signal);
      return { ok: true, reply };
    } catch (err) {
      lastError = err;
      cooldownModel(cooldowns, model, err?.message ?? String(err));
    }
  }
  if (cfg.sessionFallback === true) {
    const sessionModel = sessionModelOf(ctx);
    if (sessionModel) {
      try {
        const reply = await callLlmText(ctx, sessionModel, prompt, input, signal);
        return { ok: true, reply };
      } catch (err) {
        lastError = err;
      }
    }
  }
  return { ok: false, error: lastError };
}

// ── stages ──────────────────────────────────────────────────────────────────

async function observeStage(agent, ctx, cfg, store, signal) {
  const entries = collectSourceEntries(agent);
  const cursor = store.cursors.observer ?? -1;
  const newEntries = entries.filter((e) => e.index > cursor);
  if (newEntries.length === 0) return;

  const chunk = cfg.observeAfterTokens > 0 && estimateTokens(newEntries.map((e) => e.text).join("\n")) < cfg.observeAfterTokens
    ? newEntries
    : chunkSourceEntries(newEntries, Math.min(cfg.observerChunkMaxTokens, MAX_OBSERVER_INPUT_CHARS / 4));
  if (chunk.length === 0) return;

  const lastIndex = chunk[chunk.length - 1].index;

  // Preamble of existing high-relevance observations, so the model avoids dupes.
  const existing = store.observations
    .filter((o) => o.status !== "dropped" && o.relevance === "high")
    .slice(-12)
    .map((o) => `- ${o.content}`);
  const preamble = existing.length > 0 ? `Existing observations to avoid duplicating:\n${existing.join("\n")}\n\n` : "";

  const input = chunk.map((e) => {
    const text = e.role === "assistant" ? `[assistant] ${clip(e.text, 4000)}` : `[user] ${clip(e.text, 4000)}`;
    return text;
  }).join("\n");

  const userText = clip(`${preamble}${input}`, cfg.observerPreambleMaxTokens > 0 ? cfg.observerPreambleMaxTokens * 4 : MAX_OBSERVER_INPUT_CHARS);
  const result = await runWorkerStage(ctx, store, cfg, "observer", OBSERVER_PROMPT, userText, signal);
  if (!result.ok || !result.reply) {
    store.lastErrorAt = Date.now();
    return;
  }
  const items = extractJsonArray(result.reply);
  let added = 0;
  for (const it of items.slice(0, 20)) {
    const content = sanitize(String(it?.content ?? "").trim());
    if (!content || hasObservationContent(store, content)) continue;
    addObservation(store, {
      id: newId(),
      relevance: ["high", "medium", "low"].includes(it?.relevance) ? it.relevance : "medium",
      source: String(it?.source ?? ""),
      sourceEntryIds: chunk.map((e) => String(e.index)),
      content,
    });
    added += 1;
  }
  if (added > 0) store.cursors.observer = Math.max(cursor, lastIndex);
  else store.cursors.observer = Math.max(cursor, lastIndex);
}

async function reflectStage(ctx, cfg, store, signal) {
  const cursor = store.cursors.reflector ?? -1;
  const active = store.observations.filter((o) => o.status !== "dropped");
  const newObs = active.slice(cursor + 1);
  if (newObs.length === 0) return;
  const newObsTokens = estimateTokens(newObs.map((o) => o.content).join("\n"));
  if (newObsTokens < cfg.reflectAfterTokens) return;

  const input = newObs.slice(-cfg.agentMaxTurns).map((o) => `- [${o.relevance}] ${o.content}`).join("\n");
  const preamble = store.reflections.slice(-12).map((r) => `- ${r.content}`);
  const userText = (preamble.length ? `Existing reflections:\n${preamble.join("\n")}\n\n` : "") + input;

  const result = await runWorkerStage(ctx, store, cfg, "reflector", REFLECTOR_PROMPT, userText, signal);
  if (!result.ok || !result.reply) {
    store.lastErrorAt = Date.now();
    return;
  }
  const items = extractJsonArray(result.reply);
  let added = 0;
  for (const it of items.slice(0, 10)) {
    const content = sanitize(String(it?.content ?? "").trim());
    if (!content || store.reflections.some((r) => r.content.trim().toLowerCase() === content.toLowerCase())) continue;
    addReflection(store, { id: newId(), source: String(it?.source ?? ""), content });
    added += 1;
  }
  store.cursors.reflector = active.length - 1;
}

async function dropStage(ctx, cfg, store, signal) {
  // Dropper runs when the pool is overfull (token pressure or count cap).
  const pool = poolTokens(store);
  const fullnessMax = cfg.observationsPoolMaxTokens > 0 ? pool / cfg.observationsPoolMaxTokens : 0;
  const pressure = pool >= cfg.dropperPressureThreshold * cfg.reflectorInputMaxTokens;
  const overCount = store.observations.filter((o) => o.status !== "dropped").length > cfg.observationsPoolMax;
  if (!(fullnessMax >= cfg.dropperPoolFullnessThreshold && (pressure || overCount))) return;

  const input = store.observations.filter((o) => o.status !== "dropped").map((o) => `- [${o.id}] ${o.content}`).join("\n");
  const result = await runWorkerStage(ctx, store, cfg, "dropper", DROPPER_PROMPT, input, signal);
  if (!result.ok || !result.reply) {
    store.lastErrorAt = Date.now();
    return;
  }
  const items = extractJsonArray(result.reply);
  if (items.length > 0) {
    const kept = new Set(items.map((it) => String(it?.id ?? "")).filter(Boolean));
    if (kept.size > 0) {
      for (const o of store.observations) if (!kept.has(o.id)) o.status = "dropped";
    }
  } else {
    pruneObservations(store, cfg.observationsPoolMax);
  }
}

// ── orchestration ───────────────────────────────────────────────────────────

let running = false;
async function runPipeline(agent, ctx) {
  if (running) return; // never hammer; retry next turn
  running = true;
  try {
    const cfg = loadConfig();
    if (!cfg.memory) return;
    const sessionId = agent?.id;
    if (sessionId == null) return;
    const store = storeFor(sessionId, cfg);
    // Retry gate: after a failed run, wait before trying again.
    if (store.lastErrorAt && Date.now() - store.lastErrorAt < RETRY_GATE_MS) return;

    const controller = new AbortController();
    try {
      await observeStage(agent, ctx, cfg, store, controller.signal);
      await reflectStage(ctx, cfg, store, controller.signal);
      await dropStage(ctx, cfg, store, controller.signal);
    } catch { /* graceful: skip a stage, retry next turn */ }
    finally {
      persist(sessionId, cfg, store);
    }
  } finally {
    running = false;
  }
}

/** Immediate manual flush: merge pending into the ledger (and run the pipeline). */
async function flushAndRun(agent, ctx) {
  const sessionId = agent?.id;
  if (sessionId == null) return { ok: false, text: "No session id." };
  const cfg = loadConfig();
  if (cfg.memory && cfg.compaction !== "off") await runPipeline(agent, ctx);
  const result = flushPending(sessionId);
  return { ok: true, text: `pending flushed -> ledger: ${result.observationsAdded} observation(s) added (${result.observations} total, ${result.reflections} reflections).` };
}

function apply(ctx, config) {
  ctx.on("agent/turn-stopping", (payload) => {
    const agent = payload?.agent;
    if (!agent) return;
    // Fire-and-forget so the turn close is never blocked by a worker.
    void runPipeline(agent, ctx);
  });
}

export { name, inject, apply, runPipeline, flushAndRun };
