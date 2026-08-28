// /blackhole* commands — dsh adapter.
//
// dsh's command seam (ctx.commands.register) replaces pi's slash-command layer.
// /blackhole runs the OM pipeline and reports memory status (the actual context
// reduction stays with dsh's native /compact, which already drives the
// deterministic engine); /blackhole-memory shows the ledger; /blackhole-recall
// reuses the same engine as the `recall` tool.

import { recallExecute } from "./recall.js";
import { loadConfig, loadLedger, ledgerStats } from "./om-store.js";
import { runPipeline } from "./om.js";
import { renderSummary } from "./core/om-core.js";

const name = "blackhole-commands";
const inject = ["commands", "sessions", "llm"];

function renderStats(sessionId) {
  const s = ledgerStats(sessionId);
  return `[blackhole]\n` +
    `observations: ${s.observations} (active ${s.activeObservations})\n` +
    `reflections: ${s.reflections}\n` +
    `\nRun /compact to perform the deterministic context reduction; ` +
    `the observations/reflections above are injected into the next compaction.`;
}

function memoryView(sessionId, full) {
  const ledger = loadLedger(sessionId);
  if (full) return renderSummary(ledger.reflections, ledger.observations);
  ledger.observations = ledger.observations.filter((o) => o.status !== "dropped");
  return renderSummary(ledger.reflections, ledger.observations);
}

function apply(ctx, config) {
  ctx.commands.register({
    name: "blackhole",
    description: "Run the observational-memory pipeline and report status (use /compact to reduce context).",
    handler: async (invocation) => {
      const agent = invocation.agent;
      try { await runPipeline(agent, ctx); } catch { /* graceful */ }
      return { kind: "success", text: renderStats(agent?.id) };
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
