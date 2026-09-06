// Observational-memory store + config — dsh adapter.
//
// Owns the per-session ledger file, the pending (manual-mode) file, and the
// blackhole config, plus the injection block the compaction engine appends after
// the deterministic summary. The pure ledger shapes/renderers live in
// ./core/om-core.js; this file wires them to disk and to the dsh seams
// (session id, config path) and resolves the worker model with the
// fallback-chain + cooldown policy from the config.

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import {
  normalizeLedger,
  renderSummary,
  candidateModels,
  modelKey,
  isCooledDown,
  recordCooldownInto,
  poolTokens,
  estimateTokens,
} from "./core/om-core.js";

const DEFAULT_WORKER_MODEL = { provider: "runinfra", id: "deepseek-v4-flash", thinking: "low" };

// Full pi-blackhole-style config surface, with dsh-friendly defaults. Legacy
// keys (`memoryEnabled`, `observerWorkerModel`, `observationsPoolMax`) are
// migrated on load so existing config files keep working.
const DEFAULT_CONFIG = {
  // ── memory + compaction mode ──
  memory: true,
  compaction: "auto",          // auto | manual | off
  compactionEngine: "blackhole", // informational
  tailBehavior: "minimal",      // informational (dsh drives its own tail)
  midRunCompaction: "off",      // informational (dsh handles auto-compaction)

  // ── token thresholds ──
  observeAfterTokens: 15000,
  reflectAfterTokens: 25000,
  compactAfterTokens: 81000,

  // ── observation pool ──
  observationsPoolMaxTokens: 20000,
  observationsPoolMax: 40,       // legacy count cap (safety net)
  observationsPoolTargetTokens: 10000,
  dropperPressureThreshold: 0.7,   // fraction of reflectorInputMaxTokens
  dropperPoolFullnessThreshold: 0.1,

  // ── input budgets ──
  observerChunkMaxTokens: 40000,
  observerPreambleMaxTokens: 0,
  reflectorInputMaxTokens: 80000,
  dropperInputMaxTokens: 80000,
  agentMaxTurns: 16,

  // ── model resolution ──
  sessionFallback: true,
  model: DEFAULT_WORKER_MODEL,
  observerModel: DEFAULT_WORKER_MODEL,
  reflectorModel: DEFAULT_WORKER_MODEL,
  dropperModel: DEFAULT_WORKER_MODEL,
  observerFallbackModels: [],
  reflectorFallbackModels: [],
  dropperFallbackModels: [],

  debug: false,
  debugLog: false,
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

export function pendingPath(sessionId) {
  return join(blackholeDir(), `${String(sessionId)}.pending.json`);
}

export function configFile() {
  return join(blackholeDir(), "config.json");
}

// ── config ─────────────────────────────────────────────────────────────────

/** Shallow-merge one legacy worker model into the new key. */
function migrateModelKey(raw) {
  if (raw.observerWorkerModel && !raw.observerModel) raw.observerModel = raw.observerWorkerModel;
  if (raw.reflectorWorkerModel && !raw.reflectorModel) raw.reflectorModel = raw.reflectorWorkerModel;
  if (raw.dropperWorkerModel && !raw.dropperModel) raw.dropperModel = raw.dropperWorkerModel;
  if (raw.memoryEnabled !== undefined && raw.memory === undefined) raw.memory = raw.memoryEnabled;
  return raw;
}

function isModelLike(v) {
  return v && typeof v === "object" && typeof v.provider === "string"
    && (typeof v.id === "string" || typeof v.model === "string");
}

function normalizeModel(v, fallback) {
  if (!isModelLike(v)) return fallback;
  // Accept both `id` (canonical) and legacy `model` for the model identifier.
  const id = typeof v.id === "string" ? v.id : typeof v.model === "string" ? v.model : "";
  if (!id) return fallback;
  return {
    provider: v.provider,
    id,
    thinking: v.thinking,
    cooldownHours: Number.isFinite(v.cooldownHours) ? v.cooldownHours : undefined,
    contextWindow: Number.isFinite(v.contextWindow) ? v.contextWindow : undefined,
  };
}

function normalizeModelArray(v) {
  if (!Array.isArray(v)) return [];
  return v.map((m) => normalizeModel(m, null)).filter(Boolean);
}

export function loadConfig() {
  const cfg = { ...DEFAULT_CONFIG };
  try {
    const raw = migrateModelKey(JSON.parse(readFileSync(configFile(), "utf8")));
    if (raw && typeof raw === "object") {
      // scalar fields
      for (const key of [
        "memory", "compaction", "compactionEngine", "tailBehavior", "midRunCompaction",
        "observeAfterTokens", "reflectAfterTokens", "compactAfterTokens",
        "observationsPoolMaxTokens", "observationsPoolMax", "observationsPoolTargetTokens",
        "dropperPressureThreshold", "dropperPoolFullnessThreshold",
        "observerChunkMaxTokens", "observerPreambleMaxTokens",
        "reflectorInputMaxTokens", "dropperInputMaxTokens", "agentMaxTurns",
        "sessionFallback", "debug", "debugLog",
      ]) {
        if (raw[key] !== undefined) cfg[key] = raw[key];
      }
      cfg.model = normalizeModel(raw.model, cfg.model);
      cfg.observerModel = normalizeModel(raw.observerModel, cfg.observerModel);
      cfg.reflectorModel = normalizeModel(raw.reflectorModel, cfg.reflectorModel);
      cfg.dropperModel = normalizeModel(raw.dropperModel, cfg.dropperModel);
      cfg.observerFallbackModels = normalizeModelArray(raw.observerFallbackModels);
      cfg.reflectorFallbackModels = normalizeModelArray(raw.reflectorFallbackModels);
      cfg.dropperFallbackModels = normalizeModelArray(raw.dropperFallbackModels);
    }
  } catch { /* missing or invalid config -> defaults */ }

  // Env overrides (mirrors pi's PI_BLACKHOLE_* behavior, minimal subset).
  if (process.env.PI_BLACKHOLE_COMPACTION) {
    const v = process.env.PI_BLACKHOLE_COMPACTION.trim().toLowerCase();
    if (["auto", "manual", "off"].includes(v)) cfg.compaction = v;
  }
  if (process.env.PI_BLACKHOLE_MEMORY !== undefined) {
    const v = process.env.PI_BLACKHOLE_MEMORY.trim().toLowerCase();
    if (["1", "true", "yes", "on"].includes(v)) cfg.memory = true;
    else if (["0", "false", "no", "off"].includes(v)) cfg.memory = false;
  }
  return cfg;
}

export function saveConfig(next) {
  try {
    mkdirSync(blackholeDir(), { recursive: true });
    const current = loadConfig();
    const merged = { ...current, ...next };
    writeFileSync(configFile(), `${JSON.stringify(merged, null, 2)}\n`);
    return true;
  } catch {
    return false;
  }
}

/** Primary worker model (legacy helper) — first candidate for a stage. */
export function workerModelFor(worker, cfg) {
  const list = candidateModels(cfg, worker);
  return list[0] ?? DEFAULT_WORKER_MODEL;
}

/** Ordered model candidates for a stage, excluding cooled-down models. */
export function activeCandidateModels(worker, cfg, cooldowns) {
  return candidateModels(cfg, worker).filter((m) => !isCooledDown(cooldowns, modelKey(m)));
}

/** Record a cooldown for a model config into a cooldowns map. */
export function cooldownModel(cooldowns, model, reason) {
  recordCooldownInto(cooldowns, modelKey(model), reason, model.cooldownHours ?? 1);
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

// ── pending (manual mode) ───────────────────────────────────────────────────

export function loadPending(sessionId) {
  try {
    const raw = JSON.parse(readFileSync(pendingPath(sessionId), "utf8"));
    return normalizeLedger(raw);
  } catch {
    return normalizeLedger(null);
  }
}

export function savePending(sessionId, pending) {
  try {
    mkdirSync(blackholeDir(), { recursive: true });
    writeFileSync(pendingPath(sessionId), JSON.stringify(normalizeLedger(pending), null, 2));
  } catch { /* best-effort */ }
}

export function clearPending(sessionId) {
  try {
    if (existsSync(pendingPath(sessionId))) writeFileSync(pendingPath(sessionId), "{}");
  } catch { /* best-effort */ }
}

/** Merge pending into the ledger (manual-mode flush) and clear pending. */
export function flushPending(sessionId) {
  const pending = loadPending(sessionId);
  const ledger = loadLedger(sessionId);
  let added = 0;
  for (const o of pending.observations) {
    if (ledger.observations.some((x) => x.id === o.id)) continue;
    ledger.observations.push(o);
    added += 1;
  }
  for (const r of pending.reflections) {
    if (ledger.reflections.some((x) => x.id === r.id)) continue;
    ledger.reflections.push(r);
  }
  for (const key of ["observer", "reflector", "dropper"]) {
    if (pending.cursors?.[key] !== undefined) ledger.cursors[key] = pending.cursors[key];
  }
  if (pending.lastErrorAt) ledger.lastErrorAt = pending.lastErrorAt;
  saveLedger(sessionId, ledger);
  clearPending(sessionId);
  return { observationsAdded: added, observations: ledger.observations.length, reflections: ledger.reflections.length };
}

// ── injection (called by the compaction engine after compile()) ────────────

/**
 * Build the observational-memory block appended after the deterministic summary.
 * Returns "" when memory is disabled; otherwise the ## Reflections / ##
 * Observations block plus the recall-guidance footer (matching pi-blackhole).
 */
export function renderOmInjection(agent, _signal) {
  const cfg = loadConfig();
  if (!cfg.memory) return "";
  const sessionId = agent?.id;
  if (sessionId == null) return "";
  const ledger = loadLedger(sessionId);
  return renderSummary(ledger.reflections, ledger.observations);
}

// ── status helpers for /blackhole-memory ───────────────────────────────────

export function ledgerStats(sessionId) {
  const ledger = loadLedger(sessionId);
  const pending = loadPending(sessionId);
  return {
    observations: ledger.observations.length,
    activeObservations: ledger.observations.filter((o) => o.status !== "dropped").length,
    reflections: ledger.reflections.length,
    poolTokens: poolTokens(ledger),
    pendingObservations: pending.observations.length,
    pendingReflections: pending.reflections.length,
    observerCursor: ledger.cursors.observer,
    reflectorCursor: ledger.cursors.reflector,
    dropperCursor: ledger.cursors.dropper,
    lastErrorAt: ledger.lastErrorAt,
    cooldowns: Object.keys(ledger.cooldowns || {}),
  };
}

/** Remove orphaned pending/ledger files for sessions no longer present. */
export function cleanupOrphans(liveSessionIds) {
  const live = new Set((liveSessionIds || []).map(String));
  let removed = 0;
  try {
    for (const file of readdirSync(blackholeDir())) {
      if (!file.endsWith(".json")) continue;
      const m = file.match(/^(.+?)(\.pending)?\.json$/);
      if (!m) continue;
      const id = m[1];
      if (live.has(id)) continue;
      try {
        statSync(join(blackholeDir(), file));
        writeFileSync(join(blackholeDir(), file), "{}");
        removed += 1;
      } catch { /* ignore */ }
    }
  } catch { /* missing dir */ }
  return removed;
}

export { estimateTokens };
