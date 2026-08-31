//#region lib/index.js
/**
 * dsh-runinfra-autosync — reconcile the RunInfra route's models against the
 * live `api.runinfra.ai/v1/models` listing.
 *
 * Why this exists. Unlike opencode-go (a pi-ai *catalog* provider whose models
 * come from the installed static catalog), `runinfra` is a plain
 * openai-completions gateway that the dsh side provisions through a static
 * Nix adapter reading the pinned `monotykamary/pi-runinfra-provider` source
 * tree (`models.json` + `patch.json` + `custom-models.json`). That adapter has
 * no live path, so the moment the gateway ships a new id the dsh route is
 * stale until someone bumps the flake input and rebuilds. The pi side avoids
 * this with stale-while-revalidate (`fetchLiveModels` on session start); this
 * plugin brings the same effect to dsh, but its merge *policy* differs from
 * dsh-opencode-autosync for a reason.
 *
 * opencode-go is add-only because its route is catalog-backed and mixed-protocol:
 * a live listing that omits a catalogue model must not delete a model the
 * protocol resolver still needs. RunInfra is a single-protocol gateway whose
 * `/v1/models` list is authoritative: if the gateway no longer advertises a
 * model, the model is genuinely gone, so here we reconcile — keep live models
 * that are already configured (preserving their compat/reasoningEfforts and
 * any user-corrected capacities), add id the listing discloses but we do not
 * know, and *drop* ones the gateway no longer lists. This is exactly the
 * "在清单外的可以去掉" (drop what is outside the live list) request.
 *
 * What this plugin does. Once at startup (shortly after activation) and again
 * on a configurable interval, it:
 *   1. reads the configured `runinfra` route's models from the `llm-pi-ai`
 *      settings namespace (the writable source that decides what the route
 *      actually serves) — this is the composition `base` layered with the
 *      user document, so per-model compat and reasoningEfforts are present;
 *   2. interrogates `https://api.runinfra.ai/v1/models` through
 *      `ctx.llm.discoverModels` with the provider id omitted + the route's
 *      api-key env, returning the live id/capacity listing;
 *   3. reconciles: ids configured and still live keep their existing entry
 *      (compat, reasoningEfforts, capacity, name) untouched; ids live but not
 *      configured are appended with RunInfra-safe defaults (the gateway 400s
 *      `developer` role, reports a usable `context_window/max_output_tokens`,
 *      and serves every model over openai-completions); ids configured but no
 *      longer live are dropped;
 *   4. writes the reconciled list back through `settings.update` guarded by
 *      the namespace revision, retrying once on a stale-revision conflict.
 *
 * Model-list edits take effect on the next request — no restart. A failed or
 * empty discovery never mutates the route (empty list is treated as an
 * unavailable state rather than "the gateway dropped everything"), so a
 * transient endpoint outage cannot wipe a working model list.
 *
 * The plugin is host-only and imports nothing outside the module system: every
 * capability is resolved lazily through `ctx.get`. Startup/interval overlap is
 * prevented with a simple in-flight flag, and a failed discovery is logged and
 * left for the next tick rather than tearing the plugin down.
 */

/** Cordis plugin name used by loader diagnostics. */
const name = "runinfra-autosync";

/** Timer mixin is a hard dependency: first pass + periodic pass use ctx.timeout/ctx.interval. */
const inject = ["timer"];

/** The settings namespace owning the provider routes (matches dsh-llm-pi-ai). */
const NS = "llm-pi-ai";

/** Defaults for the route this plugin manages. */
const DEFAULT_ROUTE = "runinfra";
const DEFAULT_BASE_URL = "https://api.runinfra.ai/v1";
const DEFAULT_API = "openai-completions";
const DEFAULT_API_KEY_ENV = "RUNINFRA_GATEWAY_KEY";
/** 12h check interval; override via the plugin row's `config.intervalMs`. */
const DEFAULT_INTERVAL_MS = 12 * 60 * 60 * 1000;
/** Capacities applied to id the listing discloses but whose figures it hides. */
const DEFAULT_CONTEXT_WINDOW = 128000;
const DEFAULT_MAX_TOKENS = 32000;
/**
 * RunInfra-specific compat applied to *newly adopted* id. The gateway's role
 * whitelist is system/user/assistant/tool only (`developer` is a 400), so the
 * compat must disable the developer role; it also speaks openai-completions,
 * so the max_tokens field is the openai one. Existing configured entries keep
 * their own compat untouched (they may be deepseek/zai thinking formats the
 * gateway surfaces per-model).
 */
const NEW_MODEL_COMPAT = {
	supportsDeveloperRole: false,
	supportsStore: false,
	maxTokensField: "max_tokens",
};

/**
 * Derive a display name from a model id: split on separators, capitalize words,
 * keep version digits intact (`x-preview-f-free` → `X Preview F Free`).
 * Mirrors dsh-runinfra-autosync.shared.displayNameFromId.
 */
function displayNameFromId(id) {
	return String(id)
		.split(/[-_]+/)
		.filter((part) => part.length > 0)
		.map((part) => (/^\d/.test(part) ? part : part.charAt(0).toUpperCase() + part.slice(1)))
		.join(" ");
}

/**
 * Normalize one model entry against the llm-pi-ai schema, filling missing
 * capacity with conservative defaults but never overriding a present value.
 * Every field the schema knows survives untouched — this plugin must NOT strip
 * `compat` or `reasoningEfforts`, because RunInfra models carry meaningful
 * per-model protocol metadata that openai-completions does not infer.
 * @param entry - the draft entry (id required).
 * @returns a plain owned copy carrying the documented fields.
 */
function normalizeEntry(entry, fallbackId) {
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
	}
	if (entry.compat !== undefined && entry.compat !== null && typeof entry.compat === "object") {
		normalized.compat = entry.compat;
	}
	return normalized;
}

/** Read the route's configured models as plain owned copies. */
function readRouteModels(settings, route) {
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
	const models = Array.isArray(profile.models)
		? profile.models
			.filter((m) => m !== null && typeof m === "object" && typeof m.id === "string")
			.map((m) => normalizeEntry(m, m.id))
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
 * Reconcile the configured models against the live listing, preserving
 * existing entries (compat/reasoningEfforts/capacity) for ids still live,
 * appending new live ids with RunInfra-safe defaults, and dropping configured
 * ids no longer advertised.
 * @returns `{ merged, added, dropped }` where `added`/`dropped` are id lists.
 */
function reconcile(existing, live) {
	const existingById = new Map(existing.map((entry) => [entry.id, entry]));
	const liveIds = new Set(live.map((entry) => (typeof entry?.id === "string" ? entry.id : "")).filter(Boolean));
	const merged = [];
	const seen = new Set();
	const added = [];
	const dropped = [];

	for (const entry of existing) {
		if (!liveIds.has(entry.id)) {
			dropped.push(entry.id);
			continue;
		}
		merged.push(normalizeEntry(entry, entry.id));
		seen.add(entry.id);
	}

	for (const liveEntry of live) {
		const id = typeof liveEntry?.id === "string" ? liveEntry.id.trim() : "";
		if (id.length === 0 || seen.has(id)) continue;
		seen.add(id);
		merged.push(
			normalizeEntry(
				{
					id,
					...(typeof liveEntry.name === "string" && liveEntry.name.trim().length > 0 ? { name: liveEntry.name.trim() } : {}),
					...(typeof liveEntry.contextWindow === "number" ? { contextWindow: liveEntry.contextWindow } : {}),
					...(typeof liveEntry.maxTokens === "number" ? { maxTokens: liveEntry.maxTokens } : {}),
				},
				id
			)
		);
		if (compatOf(merged[merged.length - 1]) === undefined) {
			merged[merged.length - 1].compat = { ...NEW_MODEL_COMPAT };
		}
		added.push(id);
	}

	return { merged, added, dropped };
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
	const { exists, models: existing } = readRouteModels(settings, opts.route);
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
	const { merged, added, dropped } = reconcile(existing, live);
	if (added.length === 0 && dropped.length === 0) return { ok: true, addedCount: 0, droppedCount: 0, route: opts.route };
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

/**
 * Host plugin entry point.
 * @param ctx - cordis context.
 * @param config - the plugin row's `config` from the host patch.
 */
async function apply(ctx, config) {
	const opts = {
		route: config?.route ?? DEFAULT_ROUTE,
		baseURL: config?.baseURL ?? DEFAULT_BASE_URL,
		api: config?.api ?? DEFAULT_API,
		apiKeyEnv: config?.apiKeyEnv ?? DEFAULT_API_KEY_ENV,
		intervalMs: Number.isFinite(config?.intervalMs) ? config.intervalMs : DEFAULT_INTERVAL_MS,
	};
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
