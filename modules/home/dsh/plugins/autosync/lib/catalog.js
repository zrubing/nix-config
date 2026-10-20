//#region lib/catalog.js
/**
 * models.dev — the capability source for catalog-backed routes.
 *
 * ## Why this module exists
 *
 * A gateway `/v1/models` answers *which ids exist* and nothing else: opencode's
 * `/inference/go/v1/models` returns `id / object / created / owned_by` and
 * ignores `?detailed`, and the deepseek relay returns an empty shell. Adopting
 * an id from such a listing therefore has no capacity, no reasoning levels and
 * no modality fact — the previous generation of this plugin filled those with a
 * constant (128000 / 32000 / text-only), which is how `opencode-go` ended up
 * serving `deepseek-v4.1-flash` at a fabricated 128k while the upstream model is
 * 1M / 384k. Inventing a capacity is worse than not adopting the id: the wrong
 * number is indistinguishable from a real one at every later layer (context bar,
 * overflow detection, cost estimates).
 *
 * The numbers exist upstream. `https://models.dev/api.json` is the catalog
 * opencode's own client is generated from, and it carries `limit.context`,
 * `limit.output`, `reasoning_options`, `modalities`, `interleaved` and `cost`
 * per (provider, model id). One public GET covers every catalog-backed route we
 * have; private gateways that publish their own capacities (runinfra does) keep
 * using their own payload.
 *
 * ## Fetch discipline
 *
 * The document is ~5.9 MB (482 KB gzipped) and changes slowly, so it is cached
 * at `~/.cache/llm/models-dev.json` and revalidated with `If-None-Match`: a
 * clean pass costs one 304 and zero bytes of body. `ttlMs` skips even the
 * revalidation inside the window. A stale cache is still usable data — it is
 * returned with `stale: true` so the caller can log it, never mixed with
 * invented values.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const CATALOG_URL = "https://models.dev/api.json";
const FETCH_TIMEOUT_MS = 20000;
const DEFAULT_TTL_MS = 12 * 60 * 60 * 1000;
/** DSH accepts exactly these modalities; anything else in the catalog is dropped. */
const KNOWN_MODALITIES = ["text", "image"];

function homeDir(env) {
	const home = env?.HOME;
	return typeof home === "string" && home.length > 0 ? home : os.homedir();
}

/**
 * Cache location. A fixed `~/.cache` path rather than an XDG lookup, for the
 * same reason runinfra's published catalog uses one: the systemd unit, the TUI
 * and the interactive shells resolve the environment differently, and a cache
 * path that disagrees between writer and reader silently strands one of them.
 */
export function catalogFilePath(env = process.env) {
	return path.join(homeDir(env), ".cache", "llm", "models-dev.json");
}

function readCache(cachePath) {
	let raw;
	try {
		raw = fs.readFileSync(cachePath, "utf8");
	} catch {
		return undefined;
	}
	try {
		const parsed = JSON.parse(raw);
		if (parsed === null || typeof parsed !== "object" || typeof parsed.data !== "object" || parsed.data === null) {
			return undefined;
		}
		return {
			etag: typeof parsed.etag === "string" ? parsed.etag : undefined,
			fetchedAt: Number.isFinite(parsed.fetchedAt) ? parsed.fetchedAt : 0,
			data: parsed.data,
		};
	} catch {
		return undefined;
	}
}

function writeCache(cachePath, record) {
	fs.mkdirSync(path.dirname(cachePath), { recursive: true });
	const temporary = `${cachePath}.tmp-${process.pid}`;
	fs.writeFileSync(temporary, JSON.stringify(record));
	fs.renameSync(temporary, cachePath);
}

function staleResult(cached, reason) {
	return { providers: cached.data, fetchedAt: cached.fetchedAt, stale: true, reason };
}

/**
 * Load the catalog, revalidating the cache when it is older than `ttlMs`.
 *
 * @returns `{ providers, fetchedAt, stale, reason? }`. `stale` means the
 *          network leg failed and the cached document was used as-is; it never
 *          means "filled in with defaults".
 */
export async function loadCatalog({
	ttlMs = DEFAULT_TTL_MS,
	cachePath = catalogFilePath(),
	fetchImpl = globalThis.fetch,
	now = Date.now,
} = {}) {
	if (typeof fetchImpl !== "function") throw new Error("no fetch implementation available");
	const cached = readCache(cachePath);
	if (cached !== undefined && now() - cached.fetchedAt < ttlMs) {
		return { providers: cached.data, fetchedAt: cached.fetchedAt, stale: false };
	}
	const headers = { accept: "application/json" };
	if (cached?.etag !== undefined) headers["if-none-match"] = cached.etag;

	let response;
	try {
		response = await fetchImpl(CATALOG_URL, {
			headers,
			signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
		});
	} catch (error) {
		if (cached !== undefined) return staleResult(cached, error instanceof Error ? error.message : String(error));
		throw error;
	}

	if (response.status === 304) {
		if (cached === undefined) throw new Error(`${CATALOG_URL} answered 304 without a cached copy`);
		const refreshedAt = now();
		writeCache(cachePath, { ...cached, fetchedAt: refreshedAt });
		return { providers: cached.data, fetchedAt: refreshedAt, stale: false };
	}
	if (!response.ok) {
		const reason = `${CATALOG_URL} answered ${response.status}`;
		if (cached !== undefined) return staleResult(cached, reason);
		throw new Error(reason);
	}

	const providers = await response.json();
	const fetchedAt = now();
	const etag = typeof response.headers?.get === "function" ? response.headers.get("etag") : undefined;
	writeCache(cachePath, { ...(etag === null || etag === undefined ? {} : { etag }), fetchedAt, data: providers });
	return { providers, fetchedAt, stale: false };
}

/**
 * Pick the first provider the catalog declares under one of `ids`.
 *
 * Order matters: a route may be catalogued under its exact provider id and,
 * failing that, under the family id its gateway is generated from.
 */
export function providerSlice(providers, ids) {
	if (providers === null || typeof providers !== "object") return undefined;
	for (const id of ids) {
		const provider = providers[id];
		if (provider !== null && typeof provider === "object" && provider.models !== null && typeof provider.models === "object") {
			return provider;
		}
	}
	return undefined;
}

function positiveInt(value) {
	return typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.trunc(value) : undefined;
}

function modalitiesOf(reported) {
	if (!Array.isArray(reported)) return undefined;
	const mapped = reported.filter((entry) => KNOWN_MODALITIES.includes(entry));
	return mapped.length > 0 ? mapped : undefined;
}

/**
 * Turn one catalog record into the capability fields the llm-pi-ai schema
 * takes, or `undefined` when the record carries no usable capacity.
 *
 * Mapping (catalog → dsh):
 *   limit.context                       → contextWindow
 *   limit.output                        → maxTokens
 *   modalities.input                    → input
 *   reasoning_options[type=effort]      → reasoningEfforts (identity map: the
 *                                         gateway's effort name *is* the level)
 *   interleaved.field = reasoning_content → thinkingFormat: deepseek
 *
 * A `toggle` reasoning option has no level vocabulary, so it contributes
 * nothing: a model with only a toggle reports no effort control rather than a
 * made-up one. Fields the catalog does not state are simply absent.
 */
export function capabilityOfRecord(record) {
	if (record === null || typeof record !== "object") return undefined;
	const contextWindow = positiveInt(record.limit?.context);
	const maxTokens = positiveInt(record.limit?.output);
	if (contextWindow === undefined || maxTokens === undefined) return undefined;
	const capability = { contextWindow, maxTokens };
	if (typeof record.name === "string" && record.name.trim().length > 0) capability.name = record.name.trim();
	const input = modalitiesOf(record.modalities?.input);
	if (input !== undefined) capability.input = input;
	const efforts = {};
	if (Array.isArray(record.reasoning_options)) {
		for (const option of record.reasoning_options) {
			if (option === null || typeof option !== "object" || option.type !== "effort") continue;
			for (const value of Array.isArray(option.values) ? option.values : []) {
				if (typeof value === "string" && value.length > 0) efforts[value] = value;
			}
		}
	}
	if (Object.keys(efforts).length > 0) capability.reasoningEfforts = efforts;
	if (record.interleaved !== null && typeof record.interleaved === "object" && record.interleaved.field === "reasoning_content") {
		capability.thinkingFormat = "deepseek";
	}
	return capability;
}

/** id → capability for one provider slice; ids without capacity are omitted. */
export function capabilityMap(provider) {
	const map = new Map();
	const models = provider?.models;
	if (models === null || typeof models !== "object") return map;
	for (const [id, record] of Object.entries(models)) {
		const capability = capabilityOfRecord(record);
		if (capability !== undefined) map.set(id, capability);
	}
	return map;
}
//#endregion
