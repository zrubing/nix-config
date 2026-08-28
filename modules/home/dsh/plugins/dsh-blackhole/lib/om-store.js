// Observational-memory store + config — dsh adapter.
//
// Owns the per-session ledger file and the blackhole config, plus the injection
// block the compaction engine appends after the deterministic summary. The pure
// ledger shapes/renderers live in ./core/om-core.js; this file only wires them
// to disk and to the dsh seams (session id, config path).

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { normalizeLedger, renderSummary } from "./core/om-core.js";

const DEFAULT_WORKER_MODEL = { provider: "opencode-go", model: "deepseek-v4-flash", thinking: "low" };

const DEFAULT_CONFIG = {
  memoryEnabled: true,
  observerWorkerModel: DEFAULT_WORKER_MODEL,
  reflectorWorkerModel: DEFAULT_WORKER_MODEL,
  dropperWorkerModel: DEFAULT_WORKER_MODEL,
  observeAfterTokens: 20000,
  reflectAfterTokens: 60000,
  observationsPoolMax: 40,
  observerChunkMaxTokens: 80000,
  compactAfterTokens: 600000,
};

function dshHome() {
  return process.env.DSH_HOME ?? join(homedir(), ".dsh");
}

export function blackholeDir() {
  return join(dshHome(), "blackhole");
}

export function ledgerPath(sessionId) {
  return join(blackholeDir(), `${String(sessionId)}.json`);
}

export function configFile() {
  return join(blackholeDir(), "config.json");
}

// ── config ─────────────────────────────────────────────────────────────────

export function loadConfig() {
  const cfg = { ...DEFAULT_CONFIG };
  try {
    const raw = JSON.parse(readFileSync(configFile(), "utf8"));
    if (raw && typeof raw === "object") {
      for (const key of Object.keys(DEFAULT_CONFIG)) {
        if (raw[key] !== undefined) cfg[key] = raw[key];
      }
    }
  } catch { /* missing or invalid config -> defaults */ }
  return cfg;
}

export function workerModelFor(worker, cfg) {
  const key = worker === "observer" ? "observerWorkerModel"
    : worker === "reflector" ? "reflectorWorkerModel"
    : "dropperWorkerModel";
  return cfg[key] ?? DEFAULT_WORKER_MODEL;
}

// ── ledger ─────────────────────────────────────────────────────────────────

export function loadLedger(sessionId) {
  try {
    const raw = JSON.parse(readFileSync(ledgerPath(sessionId), "utf8"));
    return normalizeLedger(raw);
  } catch {
    return normalizeLedger(null);
  }
}

export function saveLedger(sessionId, ledger) {
  try {
    mkdirSync(blackholeDir(), { recursive: true });
    writeFileSync(ledgerPath(sessionId), JSON.stringify(normalizeLedger(ledger), null, 2));
  } catch { /* best-effort persistence; never break a compaction */ }
}

// ── injection (called by the compaction engine after compile()) ────────────

/**
 * Build the observational-memory block appended after the deterministic summary.
 * Returns "" when memory is disabled; otherwise the ## Reflections / ##
 * Observations block plus the recall-guidance footer (matching pi-blackhole).
 */
export function renderOmInjection(agent, _signal) {
  const cfg = loadConfig();
  if (!cfg.memoryEnabled) return "";
  const sessionId = agent?.id;
  if (sessionId == null) return "";
  const ledger = loadLedger(sessionId);
  return renderSummary(ledger.reflections, ledger.observations);
}

// ── status helpers for /blackhole-memory ───────────────────────────────────

export function ledgerStats(sessionId) {
  const ledger = loadLedger(sessionId);
  return {
    observations: ledger.observations.length,
    activeObservations: ledger.observations.filter((o) => o.status !== "dropped").length,
    reflections: ledger.reflections.length,
  };
}
