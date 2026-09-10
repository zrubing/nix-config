//#region lib/index.js
/**
 * dsh-deepseek-relay-autosync — reconcile the deepseek-relay route's models
 * against the live relay `/v1/models` listing.
 *
 * Why this exists. The deepseek-relay route is a plain openai-completions
 * gateway (non-catalog), so its Nix-managed model list goes stale the moment
 * the relay renames or ships a model (2026-09-10: the whole catalog collapsed
 * to `deepseek-flash`, retiring v4-flash / v4-flash-vision-exp / v4-pro /
 * v4.1-flash). The relay's `/v1/models` is authoritative for *which ids exist*,
 * so this plugin reconciles ids: keep in-scope ids still advertised (with their
 * configured compat/reasoningEfforts/capacity), adopt newly advertised ids,
 * drop in-scope ids the relay no longer lists.
 *
 * Two deliberate narrowings over the dsh-runinfra-autosync clone it was
 * derived from:
 *   1. Scope. The relay advertises far more than the DeepSeek family, while
 *      this route is hand-curated; `includePrefixes` (default `["deepseek-"]`)
 *      confines adoption/dropping to those ids. Entries outside the scope are
 *      left exactly as configured — never dropped, never overwritten.
 *   2. Capability defaults. `/v1/models` discloses only ids, so an adopted id
 *      would otherwise carry no `reasoningEfforts` — and a model without that
 *      field reports *no* reasoning capability to the harness, which silently
 *      removes the thinking-effort control from the model picker (exactly the
 *      regression seen after the rename above). `defaultReasoningEfforts` is
 *      therefore applied to every in-scope entry that does not declare the
 *      field (adopted *and* existing ones, so a settings snapshot written
 *      before this option existed heals), while an explicit
 *      `reasoningEfforts: false` is respected as a deliberate opt-out.
 *
 * The plugin is host-only and imports nothing outside the module system: every
 * capability is resolved lazily through `ctx.get`. Startup/interval overlap is
 * prevented with a simple in-flight flag, and a failed discovery is logged and
 * left for the next tick rather than tearing the plugin down.
 */

/** Cordis plugin name used by loader diagnostics. */
const name = "deepseek-relay-autosync";

/** Timer mixin is a hard dependency: first pass + periodic pass use ctx.timeout/ctx.interval. */
const inject = ["timer"];

/** The settings namespace owning the provider routes (matches dsh-llm-pi-ai). */
const NS = "llm-pi-ai";

/** Defaults for the route this plugin manages. */
const DEFAULT_ROUTE = "deepseek-relay";
const DEFAULT_BASE_URL = "https://enterprise.hallucodex.chat/v1";
const DEFAULT_API = "openai-completions";
const DEFAULT_API_KEY_ENV = "DEEPSEEK_RELAY_API_KEY";
/** Only ids starting with one of these are adopted/dropped; [] means "every id". */
const DEFAULT_INCLUDE_PREFIXES = ["deepseek-"];
/** 12h check interval; override via the plugin row's `config.intervalMs`. */
const DEFAULT_INTERVAL_MS = 12 * 60 * 60 * 1000;
/** Capacities applied to id the listing discloses but whose figures it hides. */
const DEFAULT_CONTEXT_WINDOW = 128000;
const DEFAULT_MAX_TOKENS = 32000;
/**
 * Relay-specific compat applied to *newly adopted* id: the relay 400s the
 * `developer` role and serves everything over openai-completions. Existing
 * configured entries keep their own compat untouched (deepseek-family models
 * carry thinkingFormat: deepseek there).
 */
const NEW_MODEL_COMPAT = {
	supportsDeveloperRole: false,
	supportsStore: false,
	maxTokensField: "max_tokens",
};

/**
 * Derive a display name from a model id: split on separators, capitalize words,
 * keep version digits intact (`deepseek-flash` → `Deepseek Flash`).
 */
function displayNameFromId(id) {
	return String(id)
		.split(/[-_]+/)
		.filter((part) => part.length > 0)
		.map((part) => (/^\d/.test(part) ? part : part.charAt(0).toUpperCase() + part.slice(1)))
		.join(" ");
}

/** Options stand-in for reads that must not apply capability defaults. */
const NO_DEFAULTS = {};

/** Whether an id is inside the plugin's managed scope. */
function inScope(id, prefixes) {
	if (prefixes.length === 0) return true;
	return prefixes.some((prefix) => id.startsWith(prefix));
}

/**
 * Normalize one model entry against the llm-pi-ai schema, filling missing
 * capacity with conservative defaults but never overriding a present value.
 * Every field the schema knows survives untouched — this plugin must NOT strip
 * `compat` or `reasoningEfforts`, because relay models carry meaningful
 * per-model protocol metadata that openai-completions does not infer.
 * @param entry - the draft entry (id required).
 * @param fallbackId - id to use when the draft carries none.
 * @param opts - resolved plugin options (scope + capability defaults).
 * @returns a plain owned copy carrying the documented fields.
 */
function normalizeEntry(entry, fallbackId, opts) {
	const id = typeof entry.id === "string" && entry.id.length > 0 ? entry.id : fallbackId;
	const name =
		typeof entry.name === "string" && entry.name.trim().length > 0
			? entry.name.trim()
			: displayNameFromId(id);
	const hasCapacity = (value) => typeof value === "number" && Number.isFinite(value) && value > 0;
	const normalized = {
		id,
		name,
		contextWindow: hasCapacity(entry.contextWindow) ? entry.contextWindow : DEFAULT_CONTEXT_WINDOW,
		maxTokens: hasCapacity(entry.maxTokens) ? entry.maxTokens : DEFAULT_MAX_TOKENS,
		input:
			Array.isArray(entry.input) && entry.input.length > 0
				? [...entry.input]
				: ["text"],
	};
	if (entry.reasoningEfforts !== undefined && entry.reasoningEfforts !== null) {
		normalized.reasoningEfforts = entry.reasoningEfforts;
	} else if (opts.defaultReasoningEfforts !== undefined) {
		// Absent capability metadata is what hides the effort control; `false`
		// never reaches this branch, so a deliberate opt-out survives.
		normalized.reasoningEfforts = { ...opts.defaultReasoningEfforts };
	}
	if (entry.compat !== undefined && entry.compat !== null && typeof entry.compat === "object") {
		normalized.compat = entry.compat;
	}
	return normalized;
}

/** Read the route's configured models as plain owned copies. */
function readRouteModels(settings, route, opts) {
	const section = settings.get(NS);
	if (section === undefined || section === null || typeof section !== "object") {
		return { exists: false, models: [] };
	}
	const providers = section.providers;
	const profile =
		providers !== undefined && providers !== null && typeof providers === "object"
			? providers[route]
			: undefined;
	if (profile === undefined || profile === null || typeof profile !== "object") {
		return { exists: false, models: [] };
	}
	// Read *without* capability defaults: reconcile owns that step, so it can
	// tell "undecided" (repair it) from "already declared" (leave it alone).
	const models = Array.isArray(profile.models)
		? profile.models
			.filter((m) => m !== null && typeof m === "object" && typeof m.id === "string")
			.map((m) => normalizeEntry(m, m.id, NO_DEFAULTS))
		: [];
	return { exists: true, models };
}

/** Read the namespace's current revision for optimistic writes. */
function describeRevision(settings) {
	const descriptors = typeof settings.describe === "function" ? settings.describe() : [];
	const found = descriptors.find((descriptor) => descriptor.ns === NS);
	return found === undefined ? undefined : found.revision;
}

/**
 * Interrogate the live listing through the llm-pi-ai discovery contract.
 * Provider id is intentionally omitted so the network branch runs with our
 * supplied credential rather than the catalog short-circuit.
 */
async function discoverLive(ctx, opts) {
	const llm = ctx.get("llm");
	if (llm === undefined || typeof llm.discoverModels !== "function") {
		throw new Error("llm service unavailable; live model discovery needs the llm-pi-ai adapter");
	}
	const env = typeof process !== "undefined" && process.env ? process.env : {};
	const apiKey = env[opts.apiKeyEnv];
	const models = await llm.discoverModels(NS, {
		baseURL: opts.baseURL,
		api: opts.api,
		// Only send a credential when one exists; an empty string would 401.
		...(typeof apiKey === "string" && apiKey.length > 0 ? { apiKey } : {}),
	});
	return Array.isArray(models) ? models : [];
}

/**
 * Reconcile the configured models against the live listing: keep in-scope
 * entries still advertised, drop in-scope entries the relay retired, adopt
 * newly advertised in-scope ids, and record in-scope entries that had to be
 * given the configured reasoning defaults.
 * @returns `{ merged, added, dropped, repaired }` where the latter three are id lists.
 */
function reconcile(existing, live, opts) {
	const liveIds = new Set(live.map((entry) => (typeof entry?.id === "string" ? entry.id : "")).filter(Boolean));
	const merged = [];
	const seen = new Set();
	const added = [];
	const dropped = [];
	const repaired = [];

	for (const entry of existing) {
		// Out-of-scope entries are the user's business: keep them verbatim.
		if (!inScope(entry.id, opts.includePrefixes)) {
			merged.push(entry);
			seen.add(entry.id);
			continue;
		}
		if (!liveIds.has(entry.id)) {
			dropped.push(entry.id);
			continue;
		}
		const before = entry.reasoningEfforts;
		const kept = normalizeEntry(entry, entry.id, opts);
		if (before === undefined && kept.reasoningEfforts !== undefined) repaired.push(entry.id);
		merged.push(kept);
		seen.add(entry.id);
	}

	for (const liveEntry of live) {
		const id = typeof liveEntry?.id === "string" ? liveEntry.id.trim() : "";
		if (id.length === 0 || seen.has(id) || !inScope(id, opts.includePrefixes)) continue;
		seen.add(id);
		merged.push(
			normalizeEntry(
				{
					id,
					...(typeof liveEntry.name === "string" && liveEntry.name.trim().length > 0 ? { name: liveEntry.name.trim() } : {}),
					...(typeof liveEntry.contextWindow === "number" ? { contextWindow: liveEntry.contextWindow } : {}),
					...(typeof liveEntry.maxTokens === "number" ? { maxTokens: liveEntry.maxTokens } : {}),
				},
				id,
				opts
			)
		);
		if (compatOf(merged[merged.length - 1]) === undefined) {
			merged[merged.length - 1].compat = { ...NEW_MODEL_COMPAT };
		}
		added.push(id);
	}

	return { merged, added, dropped, repaired };
}

function compatOf(entry) {
	return entry !== undefined && typeof entry.compat === "object" ? entry.compat : undefined;
}

/** One full sync pass. Never throws; returns a plain report for the log. */
async function syncOnce(ctx, opts) {
	const settings = ctx.get("settings");
	if (settings === undefined) {
		return { ok: false, reason: "settings service unavailable" };
	}
	const { exists, models: existing } = readRouteModels(settings, opts.route, opts);
	if (exists === false) {
		return { ok: false, reason: `route "${opts.route}" not declared under ${NS}.providers` };
	}
	let live;
	try {
		live = await discoverLive(ctx, opts);
	} catch (error) {
		return { ok: false, reason: `discovery failed: ${messageOf(error)}` };
	}
	// A live listing that is empty (or unreadable) must not delete the route:
	// treat it as an unavailable state and leave the route untouched.
	if (live.length === 0) {
		return { ok: false, reason: "live listing empty; leaving route untouched" };
	}
	const { merged, added, dropped, repaired } = reconcile(existing, live, opts);
	if (added.length === 0 && dropped.length === 0 && repaired.length === 0) {
		return { ok: true, addedCount: 0, droppedCount: 0, repairedCount: 0, route: opts.route };
	}
	if (settings.writable === false) return { ok: false, reason: "settings provider is read-only" };

	const patch = { providers: { [opts.route]: { models: merged } } };
	let expectedRevision = describeRevision(settings);
	try {
		await settings.update(NS, patch, expectedRevision);
	} catch (error) {
		// Another writer landed first; re-read the revision and retry once.
		if (codeOf(error) !== "SETTINGS_CONFLICT") {
			return { ok: false, reason: `write failed: ${messageOf(error)}` };
		}
		expectedRevision = describeRevision(settings);
		try {
			await settings.update(NS, patch, expectedRevision);
		} catch (retryError) {
			return { ok: false, reason: `write retry failed: ${messageOf(retryError)}` };
		}
	}
	return {
		ok: true,
		addedCount: added.length,
		added,
		droppedCount: dropped.length,
		dropped,
		repairedCount: repaired.length,
		repaired,
		route: opts.route,
	};
}

function messageOf(error) {
	if (error instanceof Error) return error.message;
	if (error !== null && typeof error === "object" && typeof error.message === "string") return error.message;
	return String(error);
}

function codeOf(error) {
	return error !== null && typeof error === "object" ? error.code : undefined;
}

/** Resolve the plugin row's config over the documented defaults. */
function resolveOptions(config) {
	const prefixes = Array.isArray(config?.includePrefixes)
		? config.includePrefixes.filter((prefix) => typeof prefix === "string" && prefix.length > 0)
		: DEFAULT_INCLUDE_PREFIXES;
	const efforts = config?.defaultReasoningEfforts;
	return {
		route: config?.route ?? DEFAULT_ROUTE,
		baseURL: config?.baseURL ?? DEFAULT_BASE_URL,
		api: config?.api ?? DEFAULT_API,
		apiKeyEnv: config?.apiKeyEnv ?? DEFAULT_API_KEY_ENV,
		intervalMs: Number.isFinite(config?.intervalMs) ? config.intervalMs : DEFAULT_INTERVAL_MS,
		includePrefixes: prefixes,
		...(efforts !== undefined && efforts !== null && typeof efforts === "object"
			? { defaultReasoningEfforts: { ...efforts } }
			: {}),
	};
}

/**
 * Host plugin entry point.
 * @param ctx - cordis context.
 * @param config - the plugin row's `config` from the host patch.
 */
async function apply(ctx, config) {
	const opts = resolveOptions(config);
	// Guard against overlapping runs that would each re-read and rewrite.
	let running = false;
	const run = async () => {
		if (running) return;
		running = true;
		try {
			const report = await syncOnce(ctx, opts);
			console.log(`[${name}] ${JSON.stringify(report)}`);
		} catch (error) {
			console.error(`[${name}] ${messageOf(error)}`);
		} finally {
			running = false;
		}
	};
	// First pass shortly after activation (lets the settings/llm services settle),
	// then a periodic pass. Both are owned by this plugin's fiber.
	ctx.timeout(() => void run(), 2000);
	ctx.effect(() => ctx.interval(() => void run(), opts.intervalMs), `${name}.interval`);
}

export { name, inject, apply };
//#endregion
