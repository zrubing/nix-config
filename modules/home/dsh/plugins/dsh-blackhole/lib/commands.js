// /blackhole* commands — dsh adapter.
//
// dsh's command seam (ctx.commands.register) replaces pi's slash-command layer.
// /blackhole flushes pending memory and runs the OM pipeline (the actual context
// reduction stays with dsh's native /compact, which already drives the
// deterministic engine and injects the OM block); /blackhole-memory shows the
// full pipeline status; /blackhole-recall reuses the `recall` tool's engine.

import { recallExecute } from "./recall.js";
import { loadConfig, loadLedger, ledgerStats, saveConfig, cleanupOrphans, blackholeDir, configFile } from "./om-store.js";
import { runPipeline, flushAndRun } from "./om.js";
import { renderSummary } from "./core/om-core.js";

const name = "blackhole-commands";
const inject = ["commands", "sessions", "llm"];

function renderStats(sessionId) {
  const s = ledgerStats(sessionId);
  const cfg = loadConfig();
  const lines = [
    "[blackhole]",
    `mode: ${cfg.compaction} (memory ${cfg.memory ? "on" : "off"})`,
    `observations: ${s.observations} (active ${s.activeObservations})`,
    `reflections: ${s.reflections}`,
    `observation pool: ~${s.poolTokens} tokens`,
    `cursors: observer #${s.observerCursor}, reflector #${s.reflectorCursor}, dropper #${s.dropperCursor}`,
  ];
  if (s.pendingObservations > 0 || s.pendingReflections > 0) {
    lines.push(`pending (manual): ${s.pendingObservations} observation(s), ${s.pendingReflections} reflection(s)`);
  }
  if (s.lastErrorAt) lines.push(`last error: ${new Date(s.lastErrorAt).toISOString()} (retrying after cooldown)`);
  if (s.cooldowns.length > 0) lines.push(`cooled-down models: ${s.cooldowns.join(", ")}`);
  lines.push("", "Run /compact to perform the deterministic context reduction; the observations/reflections above are injected into the next compaction.");
  return lines.join("\n");
}

function memoryView(sessionId, full) {
  const ledger = loadLedger(sessionId);
  if (!full) ledger.observations = ledger.observations.filter((o) => o.status !== "dropped");
  return renderSummary(ledger.reflections, ledger.observations);
}

function renderConfig() {
  const cfg = loadConfig();
  const path = configFile();
  const lines = [
    `[blackhole config] ${path}`,
    `memory: ${cfg.memory}`,
    `compaction: ${cfg.compaction}`,
    `observeAfterTokens: ${cfg.observeAfterTokens}`,
    `reflectAfterTokens: ${cfg.reflectAfterTokens}`,
    `compactAfterTokens: ${cfg.compactAfterTokens}`,
    `observationsPoolMaxTokens: ${cfg.observationsPoolMaxTokens}`,
    `observerChunkMaxTokens: ${cfg.observerChunkMaxTokens}`,
    `observer model: ${cfg.observerModel?.provider}/${cfg.observerModel?.id}`,
    `reflector model: ${cfg.reflectorModel?.provider}/${cfg.reflectorModel?.id}`,
    `dropper model: ${cfg.dropperModel?.provider}/${cfg.dropperModel?.id}`,
    "",
    "Edit the file directly, or use /blackhole om-off | om-on to toggle memory.",
  ];
  return lines.join("\n");
}

function apply(ctx, config) {
  ctx.commands.register({
    name: "blackhole",
    description: "Flush pending observational memory, run the pipeline, or toggle memory (om-off/om-on, configure, cleanup).",
    handler: async (invocation) => {
      const agent = invocation.agent;
      const sub = (invocation.rawInput ?? "").trim().split(/\s+/)[0] ?? "";
      if (sub === "om-off") {
        saveConfig({ memory: false });
        return { kind: "success", text: "Observational memory disabled (memory: false)." };
      }
      if (sub === "om-on") {
        saveConfig({ memory: true });
        return { kind: "success", text: "Observational memory enabled (memory: true)." };
      }
      if (sub === "configure") {
        return { kind: "success", text: renderConfig() };
      }
      if (sub === "cleanup") {
        const liveIds = (ctx.sessions?.list?.() ?? []).map((s) => s?.id).filter(Boolean);
        const removed = cleanupOrphans(liveIds);
        return { kind: "success", text: `blackhole cleanup: cleared ${removed} orphaned file(s).` };
      }
      // default: flush + run pipeline + status
      let text = "";
      try {
        const res = await flushAndRun(agent, ctx);
        text = res.text ? `${res.text}\n` : "";
      } catch { /* graceful */ }
      return { kind: "success", text: `${text}${renderStats(agent?.id)}` };
    },
  });

  ctx.commands.register({
    name: "blackhole-memory",
    description: "Show observational-memory pipeline status, view, or full.",
    input: { hint: "[status|view|full]" },
    handler: (invocation) => {
      const agent = invocation.agent;
      const sub = (invocation.rawInput ?? "").trim().split(/\s+/)[0] ?? "status";
      const text = sub === "view" ? memoryView(agent?.id, false)
        : sub === "full" ? memoryView(agent?.id, true)
        : renderStats(agent?.id);
      return { kind: "success", text };
    },
  });

  ctx.commands.register({
    name: "blackhole-recall",
    description: "Search session history — same engine as the `recall` tool.",
    input: { hint: "<query> [page:N] [scope:all] [mode:file|touched]" },
    handler: async (invocation) => {
      const args = parseRecallArgs(invocation.rawInput);
      const text = await recallExecute(args, { agent: invocation.agent });
      return { kind: "success", text: typeof text === "string" ? text : JSON.stringify(text) };
    },
  });
}

/** Parse a free-form /blackhole-recall line into the recall tool's args. */
function parseRecallArgs(raw) {
  const s = (raw ?? "").trim();
  const args = {};
  let tokens = s.split(/\s+/).filter(Boolean);
  args.page = numberArg(tokens, "page:");
  const modeTok = tokens.find((t) => t.startsWith("mode:"));
  if (modeTok) { args.mode = modeTok.split(":")[1]; }
  const scopeTok = tokens.find((t) => t.startsWith("scope:"));
  if (scopeTok) { args.scope = scopeTok.split(":")[1]; }
  tokens = tokens.filter((t) => !/^(page|mode|scope):/.test(t));
  const query = tokens.join(" ");
  if (query) args.query = query;
  else args.query = "";
  return args;
}

function numberArg(tokens, prefix) {
  const t = tokens.find((x) => x.startsWith(prefix));
  if (!t) return undefined;
  const n = parseInt(t.slice(prefix.length), 10);
  return Number.isFinite(n) ? n : undefined;
}

export { name, inject, apply };
