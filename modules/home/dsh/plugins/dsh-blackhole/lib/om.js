// Observational-memory workers — dsh adapter.
//
// Mirrors pi-blackhole's background observer/reflector/dropper trio, but runs
// the LLM calls over dsh's `ctx.llm` (pi's agentLoop cannot load in dsh). Each
// worker is a single-shot structured call, chunked down for long sessions and
// guarded so a failure never blocks or breaks the conversation — matching
// pi-blackhole's "graceful degradation" (skip a stage, retry next turn, no
// hammering). The workers persist to the per-session ledger and the compaction
// engine injects them via renderOmInjection().

import { toPiMessages } from "./to-pi.js";
import { loadConfig, loadLedger, saveLedger, workerModelFor } from "./om-store.js";
import {
  addObservation, addReflection, pruneObservations, renderSummary,
  newId, OBSERVER_PROMPT, REFLECTOR_PROMPT, DROPPER_PROMPT,
} from "./core/om-core.js";
import { textOfBlocks, clip } from "./core/util.js";

const name = "blackhole-om";
const inject = ["sessions", "llm"];

/** Collect a concise transcript of a session's recent turns into one block. */
function transcript(agent, maxChars = 120000) {
  const messages = agent?.session?.deriveMessages?.() ?? [];
  let text = "";
  for (const msg of messages.slice(-40)) {
    const role = msg.role === "user" ? "user" : "assistant";
    if (msg.role === "user" && (msg.content || []).some((p) => p?.type === "tool-result")) continue;
    const body = textOfBlocks(msg.content);
    if (!body) continue;
    text += `[${role}] ${body}\n`;
    if (text.length > maxChars) break;
  }
  return clip(text, maxChars);
}

/** Structured single-shot LLM call -> text (concatenate text deltas). */
async function callLlmText(ctx, provider, model, system, userText, signal) {
  const stream = ctx.llm.stream({
    provider,
    model,
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

async function observe(agent, ctx, cfg, signal) {
  const sessionId = agent?.id;
  const text = transcript(agent);
  if (!text) return;
  const model = workerModelFor("observer", cfg);
  const reply = await callLlmText(ctx, model.provider, model.model, OBSERVER_PROMPT, text, signal);
  const items = extractJsonArray(reply);
  if (items.length === 0) return;
  const ledger = loadLedger(sessionId);
  for (const it of items.slice(0, 20)) {
    const content = String(it?.content ?? "").trim();
    if (content) addObservation(ledger, {
      id: newId(), relevance: it?.relevance ?? "medium",
      source: String(it?.source ?? ""), content,
    });
  }
  saveLedger(sessionId, ledger);
}

async function reflect(agent, ctx, cfg, signal) {
  const sessionId = agent?.id;
  const ledger = loadLedger(sessionId);
  const active = ledger.observations.filter((o) => o.status !== "dropped").slice(-30);
  if (active.length === 0) return;
  const model = workerModelFor("reflector", cfg);
  const input = active.map((o) => `- [${o.relevance}] ${o.content}`).join("\n");
  const reply = await callLlmText(ctx, model.provider, model.model, REFLECTOR_PROMPT, input, signal);
  const items = extractJsonArray(reply);
  for (const it of items.slice(0, 10)) {
    const content = String(it?.content ?? "").trim();
    if (content) addReflection(ledger, { id: newId(), source: String(it?.source ?? ""), content });
  }
  saveLedger(sessionId, ledger);
}

async function drop(agent, ctx, cfg, signal) {
  const sessionId = agent?.id;
  const ledger = loadLedger(sessionId);
  if (ledger.observations.length <= cfg.observationsPoolMax) return;
  const model = workerModelFor("dropper", cfg);
  const input = ledger.observations.map((o) => `- [${o.id}] ${o.content}`).join("\n");
  const reply = await callLlmText(ctx, model.provider, model.model, DROPPER_PROMPT, input, signal);
  const items = extractJsonArray(reply);
  if (items.length > 0) {
    const kept = new Set(items.map((it) => String(it?.id ?? "")));
    for (const o of ledger.observations) if (kept.size && !kept.has(o.id)) o.status = "dropped";
    saveLedger(sessionId, ledger);
  } else {
    pruneObservations(ledger, cfg.observationsPoolMax);
    saveLedger(sessionId, ledger);
  }
}

let running = false;
async function runPipeline(agent, ctx) {
  if (running) return; // never hammer; retry next turn
  running = true;
  const cfg = loadConfig();
  const controller = new AbortController();
  try {
    if (cfg.memoryEnabled) {
      await observe(agent, ctx, cfg, controller.signal);
      await reflect(agent, ctx, cfg, controller.signal);
      await drop(agent, ctx, cfg, controller.signal);
    }
  } catch { /* graceful: skip a stage, retry next turn */ }
  finally { running = false; }
}

function apply(ctx, config) {
  ctx.on("agent/turn-stopping", (payload) => {
    const agent = payload?.agent;
    if (!agent) return;
    // Fire-and-forget so the turn close is never blocked by a worker.
    void runPipeline(agent, ctx);
  });
}

export { name, inject, apply, runPipeline };
