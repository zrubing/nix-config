//#region lib/index.js
/**
 * dsh-opencode-autosync — automatic live discovery of the opencode.ai Go tier.
 *
 * Why this exists. dsh-llm-pi-ai's `discoverModels` answers a route that names a
 * pi-ai catalog provider from the installed static catalog, with no network
 * call at all (`lib/index.js`: `if (request.provider !== void 0) { const
 * installed = catalogModels(request.provider); if (installed.size > 0) return
 * [...catalog] }`). `opencode-go` is one such catalog provider, so the
 * on-demand `dsh-opencode-models` plugin (and the Models page "fetch available
 * models" action) reconcile opencode-go against pi-ai's static 19-model
 * catalog, never against opencode.ai. It would even flag every manually-added
 * model outside that catalog as "stale".
 *
 * To get the live opencode.ai list for a catalog provider, the only route is to
 * call the discovery contract with the provider id omitted and the endpoint +
 * credential supplied by the caller — then `discoverModels` takes its network
 * branch (`request.apiKey ?? await storedApiKey?.()`; `storedApiKey` returns
 * `undefined` when no provider is given, so the key must come from us).
 *
 * What this plugin does. Once at dsh startup (shortly after activation) and
 * again on a configurable interval, it:
 *   1. reads the configured `opencode-go` route's models from the
 *      `llm-pi-ai` settings namespace (the writable source that decides what a
 *      route actually serves);
 *   2. interrogates `https://opencode.ai/zen/go/v1/models` through
 *      `ctx.llm.discoverModels` with provider omitted + the route's api-key env,
 *      returning the live id list;
 *   3. merges add-only: ids already configured keep their existing capacities
 *      (so the user's manual values and reasoning levels survive), ids the
 *      listing discloses but the catalog/route does not yet know are appended
 *      with conservative defaults (128k context / 32k max / text input), and
 *      nothing is ever removed;
 *   4. writes the merged list back through `settings.update` guarded by the
 *      namespace revision, retrying once on a stale-revision conflict.
 *
 * Model-list edits take effect on the next request — no restart.
 *
 * The plugin is host-only and imports nothing outside the module system: every
 * capability is resolved lazily through `ctx.get`. Startups/interval overlap is
 * prevented with a simple in-flight flag, and a failed discovery is logged and
 * left for the next tick rather than tearing the plugin down.
 */

/** Cordis plugin name used by loader diagnostics. */
const name = "opencode-autosync";

/** Timer mixin is a hard dependency: first pass + periodic pass use ctx.timeout/ctx.interval. */
const inject = ["timer"];

/** The settings namespace owning the provider routes (matches dsh-llm-pi-ai). */
const NS = "llm-pi-ai";

/** Defaults for the route this plugin manages. */
const DEFAULT_ROUTE = "opencode-go";
const DEFAULT_BASE_URL = "https://opencode.ai/zen/go/v1";
const DEFAULT_API = "openai-completions";
const DEFAULT_API_KEY_ENV = "OPENCODE_API_KEY";
/** 12h check interval; override via the plugin row's `config.intervalMs`. */
const DEFAULT_INTERVAL_MS = 12 * 60 * 60 * 1000;
/** Capacities applied to ids the listing discloses but whose figures it hides. */
const DEFAULT_CONTEXT_WINDOW = 128000;
const DEFAULT_MAX_TOKENS = 32000;

/**
 * Derive a display name from a model id: split on separators, capitalize words,
 * keep version digits intact (`x-preview-f-free` → `X Preview F Free`).
 * Mirrors dsh-opencode-models.shared.displayNameFromId.
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
 * @param entry - the draft entry (id required).
 * @returns a plain owned copy carrying the documented fields.
 */
function normalizeEntry(entry, fallbackId) {
	const id = typeof entry.id === "string" && entry.id.length > 0 ? entry.id : fallbackId;
	const name =
		typeof entry.name === "string" && entry.name.trim().length > 0
			? entry.name.trim()
			: displayNameFromId(id);
	const normalized = {
		id,
		name,
		contextWindow: typeof entry.contextWindow === "number" ? entry.contextWindow : DEFAULT_CONTEXT_WINDOW,
		maxTokens: typeof entry.maxTokens === "number" ? entry.maxTokens : DEFAULT_MAX_TOKENS,
		input: Array.isArray(entry.input) && entry.input.length > 0 ? [...entry.input] : ["text"],
	};
	if (entry.reasoningEfforts !== undefined) normalized.reasoningEfforts = entry.reasoningEfforts;
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
 * Provider id is intentionally omitted so the catalog short-circuit is skipped
 * and the network branch runs with our supplied credential.
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
 * Merge the live listing into the configured models, add-only.
 * Existing ids keep their own entry (including any capacity the user corrected
 * and any reasoning-level map); new ids are appended with defaults.
 * @returns `{ merged, added }` where `added` is the list of newly adopted ids.
 */
function mergeAddOnly(existing, live) {
	const known = new Set(existing.map((entry) => entry.id));
	const merged = existing.map((entry) => normalizeEntry(entry, entry.id));
	const added = [];
	for (const entry of live) {
		const id = typeof entry?.id === "string" ? entry.id.trim() : "";
		if (id.length === 0 || known.has(id)) continue;
		known.add(id);
		merged.push(normalizeEntry({ id, ...(typeof entry.name === "string" ? { name: entry.name } : {}) }, id));
		added.push(id);
	}
	return { merged, added };
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
	const { merged, added } = mergeAddOnly(existing, live);
	if (added.length === 0) return { ok: true, addedCount: 0, route: opts.route };
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
	return { ok: true, addedCount: added.length, added, route: opts.route };
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
