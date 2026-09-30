/**
 * RunInfra provider — registered from the catalog dsh publishes.
 *
 * One syncer, one source of truth: the RunInfra gateway listing. The dsh
 * autosync descriptor `dsh-autosync/runinfra`
 * (modules/home/dsh/plugins/autosync/lib/runinfra.js) is the only thing that
 * fetches `api.runinfra.ai/v1/models`; it reconciles the dsh route and
 * publishes the reconciled catalog to
 *
 *   ~/.cache/llm/runinfra-models.json
 *
 * This extension only reads that file. It replaced the upstream
 * `monotykamary/pi-runinfra-provider` package (retired 2026-09-30): that
 * extension embedded its own `models.json` snapshot and never dropped an id
 * the gateway had renamed, so pi kept offering `deepseek-v4-flash` /
 * `deepseek-v4-pro` / `qwen3-8-2-4t-a95b` long after dsh had converged on the
 * live five. Registering the published list makes both clients show the same
 * models with the same metadata.
 *
 * The last catalog this extension read is copied to
 * `$PI_CODING_AGENT_DIR/cache/runinfra-models.json`, so a pi session that
 * starts before dsh's first pass still has models.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";

const PROVIDER_ID = "runinfra";
const BASE_URL = "https://api.runinfra.ai/v1";
const API = "openai-completions";
const CATALOG_VERSION = 1;

const agentDir = process.env.PI_CODING_AGENT_DIR ?? path.join(os.homedir(), ".pi", "agent");
// Fixed `~/.cache` path, matching the publisher (see the dsh descriptor): the
// dsh-web service and this shell resolve XDG differently, so both sides pin the
// same literal location instead of looking one up.
const CATALOG_PATH = path.join(os.homedir(), ".cache", "llm", "runinfra-models.json");
const CACHE_PATH = path.join(agentDir, "cache", "runinfra-models.json");

/**
 * Read a catalog file. Both the published file and pi's own copy carry the
 * same envelope, and a file without it is rejected on purpose: pi's pre-2026-09-30
 * cache at this path is a bare array of the retired extension's never-pruned
 * list, and picking that up would re-register exactly the stale ids this
 * extension exists to drop.
 */
function readCatalog(file: string): unknown[] | undefined {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
    const models =
      parsed?.version === CATALOG_VERSION && parsed?.provider === PROVIDER_ID && Array.isArray(parsed?.models)
        ? parsed.models
        : undefined;
    return models !== undefined && models.length > 0 ? models : undefined;
  } catch {
    return undefined;
  }
}

function writeCache(models: unknown[]): void {
  try {
    fs.mkdirSync(path.dirname(CACHE_PATH), { recursive: true });
    fs.writeFileSync(CACHE_PATH, JSON.stringify({ version: CATALOG_VERSION, provider: PROVIDER_ID, models }, null, 2) + "\n");
  } catch {
    // Cache write failure is non-fatal: the published catalog is the source.
  }
}

export default function (pi: any) {
  let models: unknown[] = readCatalog(CACHE_PATH) ?? [];

  const register = (list: unknown[]) => {
    if (list.length === 0) return;
    pi.registerProvider(PROVIDER_ID, {
      baseUrl: BASE_URL,
      apiKey: "$RUNINFRA_GATEWAY_KEY",
      api: API,
      models: list,
    });
  };

  const published = readCatalog(CATALOG_PATH);
  if (published !== undefined) {
    models = published;
    writeCache(published);
  }
  register(models);

  // RunInfra traces requests through this header; a fresh UUID per call keeps
  // server-side logs and idempotency scoped to a single attempt.
  pi.on("before_provider_request", (event: any, ctx: any) => {
    const model = ctx.model;
    if (!model || model.provider !== PROVIDER_ID) return;
    const payload = event.payload;
    if (!payload || typeof payload !== "object") return;
    payload.headers = { ...(payload.headers || {}), "X-Client-Request-Id": randomUUID() };
    return payload;
  });

  const refresh = () => {
    const fresh = readCatalog(CATALOG_PATH);
    if (fresh === undefined || JSON.stringify(fresh) === JSON.stringify(models)) return;
    models = fresh;
    register(fresh);
    writeCache(fresh);
  };

  // Register what is on disk right away (provider registration is a startup
  // concern); the re-read below is session-scoped.
  refresh();

  // No timers in the factory (pi loads extensions without starting a session);
  // arm the re-read from session_start and tear it down idempotently. dsh may
  // publish while pi is running, so a slow poll keeps a long session in step.
  let timer: ReturnType<typeof setInterval> | undefined;
  pi.on("session_start", () => {
    refresh();
    if (timer === undefined) {
      timer = setInterval(refresh, 5 * 60 * 1000);
      timer.unref?.();
    }
  });
  pi.on("session_shutdown", () => {
    if (timer !== undefined) {
      clearInterval(timer);
      timer = undefined;
    }
  });
}
