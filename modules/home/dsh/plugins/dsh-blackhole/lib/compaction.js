// pi-blackhole deterministic compaction — dsh engine adapter.
//
// This is a THIN adapter now: the deterministic compile() pipeline is imported
// from the pi-blackhole package (bundled by nix into ./core/compile.js by the
// dsh-blackhole package in modules/home/dsh/plugins/dsh-blackhole). dsh owns
// only the seams:
// mapping dsh Message[] -> pi Message[] (to-pi.js), recovering the prior
// <compacted-summary> checkpoint, and appending the observational-memory
// injection block. No summary logic lives here — an upstream pi-blackhole
// update flows through a re-build, not a manual re-port.
//
// Subclasses BasicCompactionEngine (dsh-compaction-basic) and overrides ONLY
// summarize(): pressure thresholds, /compact, <compacted-summary> framing and
// the tool-result pruner stay as dsh ships them. This is a backend swap.

import { BasicCompactionEngine } from "@deepseek-ai/dsh-compaction-basic";
import { toPiMessages } from "./to-pi.js";
import { compile } from "./core/compile.js";
import { renderOmInjection } from "./om-store.js";

const name = "blackhole-compact";
const inject = ["llm", "tokenMeter", "sessions"];
const Config = BasicCompactionEngine.Config;

/** Recover the prior <compacted-summary> checkpoint from the shadowed span. */
function recoverPreviousSummary(messages) {
  for (const msg of messages || []) {
    if (msg?.role !== "user") continue;
    for (const part of msg?.content || []) {
      if (part?.type !== "text") continue;
      const m = String(part.text || "").match(/<compacted-summary>([\s\S]*?)<\/compacted-summary>/);
      if (m) return m[1];
    }
  }
  return undefined;
}

// ── engine subclass: override ONLY summarize() ──────────────────────────────

class BlackholeCompactionEngine extends BasicCompactionEngine {
  async summarize(input, agent, signal) {
    if (signal) signal.throwIfAborted();
    const piMessages = toPiMessages(input.messages);
    const summary = compile({
      messages: piMessages,
      previousSummary: recoverPreviousSummary(input.messages),
    });
    if (!summary || !summary.trim()) {
      throw new Error("deterministic compaction produced no summary content");
    }
    const om = renderOmInjection(agent, signal);
    const text = om ? `${summary}\n\n${om}` : summary;
    return {
      summary: [{ type: "text", text }],
      provider: "pi-blackhole",
      model: "deterministic-vcc",
    };
  }
}

function apply(ctx, config) {
  ctx.plugin(BlackholeCompactionEngine, config);
}

export { name, inject, Config, apply, BlackholeCompactionEngine };
