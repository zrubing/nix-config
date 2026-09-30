//#region lib/plugin.js
/**
 * dsh-autosync — the skeleton shared by the three live model-list sync plugins
 * (`./opencode`, `./runinfra`, `./deepseek-relay`).
 *
 * ## Why one module instead of three packages
 *
 * The three plugins differ in exactly two things: their route defaults, and
 * their merge *policy*. Everything around that — reading the `llm-pi-ai`
 * settings namespace, interrogating the discovery contract, the
 * conflict-retrying write loop, the activation shape — was the same code, and
 * it was copied three times. Every fix therefore had to be applied three times
 * (2026-09-30: the write loop below was rewritten in all three after each
 * first pass died on a stale-revision conflict), and the copies had already
 * drifted: only the runinfra/relay variants preserved a configured entry's
 * `compat`, so opencode-go silently dropped that field on every sync. One
 * module, three descriptors, no drift.
 *
 * ## Why these plugins exist at all
 *
 * dsh-llm-pi-ai's `discoverModels` answers a request that names a pi-ai
 * *catalog* provider from the installed static catalog with no network call
 * (`if (request.provider !== void 0) { const installed = catalogModels(...);
 * if (installed.size > 0) return [...catalog] }`), and a non-catalog route has
 * no live path either — its model list comes from the Nix-managed profile
 * patch and goes stale the moment the gateway renames or ships a model. To
 * reach the live listing the provider id must be omitted and the endpoint +
 * credential supplied by the caller: that is the network branch
 * (`request.apiKey ?? await storedApiKey?.()`; `storedApiKey` returns
 * `undefined` when no provider is given, so the key has to come from us).
 *
 * So, once at dsh startup (shortly after activation) and again on a
 * configurable interval, each plugin:
 *   1. reads its route's configured models from the `llm-pi-ai` settings
 *      namespace — the writable source that decides what the route actually
 *      serves, so per-model `compat` and `reasoningEfforts` are present;
 *   2. interrogates the route's `/v1/models` through `ctx.llm.discoverModels`
 *      with the provider id omitted;
 *   3. merges the listing into the configured list under its policy (below);
 *   4. writes the result back through `settings.update` guarded by the
 *      namespace revision.
 *
 * Model-list edits take effect on the next request — no restart. Every failure
 * is logged and left for the next tick rather than tearing the plugin down.
 *
 * ## The two policies
 *
 * `reconcile` (runinfra, deepseek-relay): a `models` list *replaces* the
 * served catalog rather than extending it, and a single-protocol gateway's
 * `/v1/models` is authoritative for which ids exist — so ids the gateway no
 * longer advertises are dropped, ids it added are adopted, and ids still
 * advertised keep their configured entry untouched.
 *
 * `add-only` (opencode-go): the route is catalog-backed and mixed-protocol, so
 * a live listing that omits a catalog model must not delete a model the
 * protocol resolver still needs, and a catalog id must not be adopted either —
 * adopting it would swap the catalog's real capacities / reasoning levels /
 * compat for this plugin's conservative defaults, permanently (adoption is
 * add-only). Nothing is ever removed; only ids neither the route nor the
 * catalog declares are appended.
 *
 * A live listing that is empty never mutates the route: in reconcile mode it
 * would read as "the gateway dropped everything", and in add-only mode it
 * carries nothing to adopt.
 *
 * ## Descriptor hooks
 *
 * A descriptor may supply two functions on top of the policy above:
 *
 *   discover(ctx, opts)        replaces the llm-pi-ai discovery contract as
 *                              the live-listing source. runinfra uses it to
 *                              read the gateway's raw /v1/models payload
 *                              (reasoning_efforts / input_modalities / pricing
 *                              are not part of what discoverModels returns).
 *   publish({ opts, live, merged })
 *                              runs after every pass that leaves the route
 *                              consistent (write succeeded, or nothing
 *                              changed), so consumers outside dsh can read the
 *                              same catalog instead of syncing a second time.
 */
export const NS = "llm-pi-ai";

/** 12h check interval; override via the plugin row's `config.intervalMs`. */
const DEFAULT_INTERVAL_MS = 12 * 60 * 60 * 1000;
/** Capacities applied to an id the listing discloses but whose figures it hides. */
const DEFAULT_CONTEXT_WINDOW = 128000;
const DEFAULT_MAX_TOKENS = 32000;
/**
 * Compat applied to *newly adopted* ids on the gateways this plugin manages.
 * Both 400 the `developer` role and speak openai-completions, so the openai
 * `max_tokens` field is the right one. Existing configured entries keep their
 * own compat untouched — they may be deepseek/zai thinking formats the gateway
 * surfaces per-model, which openai-completions does not infer.
 */
const NEW_MODEL_COMPAT = {
	supportsDeveloperRole: false,
	supportsStore: false,
	maxTokensField: "max_tokens",
};
/**
 * Write attempts per pass. The namespace has several writers (the other two
 * autosync plugins, dsh-tap's host mirror, the settings forms), and every
 * accepted write reloads the profile, so conflicts are expected rather than
 * exceptional.
 */
const WRITE_ATTEMPTS = 4;

/**
 * Derive a display name from a model id: split on separators, capitalize words,
 * keep version digits intact (`x-preview-f-free` → `X Preview F Free`).
 * Mirrors dsh-opencode-models.shared.displayNameFromId.
 */
export function displayNameFromId(id) {
	return String(id)
		.split(/[-_]+/)
		.filter((part) => part.length > 0)
		.map((part) => (/^\d/.test(part) ? part : part.charAt(0).toUpperCase() + part.slice(1)))
		.join(" ");
}

export function messageOf(error) {
	if (error instanceof Error) return error.message;
	if (error !== null && typeof error === "object" && typeof error.message === "string") return error.message;
	return String(error);
}

export function codeOf(error) {
	return error !== null && typeof error === "object" ? error.code : undefined;
}

function hasCapacity(value) {
	return typeof value === "number" && Number.isFinite(value) && value > 0;
}

/** Whether an id is inside the plugin's managed scope (`[]` means "every id"). */
export function inScope(id, prefixes) {
	if (prefixes.length === 0) return true;
	return prefixes.some((prefix) => id.startsWith(prefix));
}

/**
 * Normalize one model entry against the llm-pi-ai schema, filling missing
 * capacity with conservative defaults but never overriding a present value.
 * Every field the schema knows survives untouched: stripping `compat` or
 * `reasoningEfforts` would silently downgrade a model that carries meaningful
 * per-model protocol metadata (the copies had exactly that bug).
 *
 * `opts.defaultReasoningEfforts` supplies the capability metadata a listing
 * that discloses only ids cannot: a model without the field reports *no*
 * reasoning capability, which removes the thinking-effort control from the
 * model picker. It is applied to every in-scope entry that does not declare
 * the field (adopted *and* freshly read existing ones, so a settings snapshot
 * written before the option existed heals), while an explicit
 * `reasoningEfforts: false` is respected as a deliberate opt-out.
 *
 * @param entry - the draft entry (id required).
 * @param fallbackId - id to use when the draft carries none.
 * @param opts - resolved plugin options (capability defaults).
 * @returns a plain owned copy carrying the documented fields.
 */
export function normalizeEntry(entry, fallbackId, opts) {
	const id = typeof entry.id === "string" && entry.id.length > 0 ? entry.id : fallbackId;
	const name =
		typeof entry.name === "string" && entry.name.trim().length > 0
			? entry.name.trim()
			: displayNameFromId(id);
	const normalized = {
		id,
		name,
		contextWindow: hasCapacity(entry.contextWindow) ? entry.contextWindow : DEFAULT_CONTEXT_WINDOW,
		maxTokens: hasCapacity(entry.maxTokens) ? entry.maxTokens : DEFAULT_MAX_TOKENS,
		input: Array.isArray(entry.input) && entry.input.length > 0 ? [...entry.input] : ["text"],
	};
	if (entry.reasoningEfforts !== undefined && entry.reasoningEfforts !== null) {
		// `false` is a deliberate opt-out and must survive verbatim.
		normalized.reasoningEfforts =
			typeof entry.reasoningEfforts === "object" ? { ...entry.reasoningEfforts } : entry.reasoningEfforts;
	} else if (opts.defaultReasoningEfforts !== undefined) {
		normalized.reasoningEfforts = { ...opts.defaultReasoningEfforts };
	}
	if (entry.compat !== undefined && entry.compat !== null && typeof entry.compat === "object") {
		normalized.compat = { ...entry.compat };
	}
	return normalized;
}

/**
 * Read the id-indexed slice of a live listing entry that describes capability
 * the configured entry may not have yet. A descriptor whose `discover` returns
 * richer entries than the llm-pi-ai contract (see `discover`) gets its
 * `input` / `reasoningEfforts` copied onto adopted *and* existing entries, so
 * one id set has one capability story for every consumer.
 */
function capabilityOf(entry) {
	if (entry === undefined || entry === null || typeof entry !== "object") return {};
	const out = {};
	if (Array.isArray(entry.input) && entry.input.length > 0) out.input = [...entry.input];
	if (entry.reasoningEfforts !== undefined && entry.reasoningEfforts !== null) {
		out.reasoningEfforts = typeof entry.reasoningEfforts === "object" ? { ...entry.reasoningEfforts } : entry.reasoningEfforts;
	}
	return out;
}

/**
 * Read the live descriptor for NS (undefined when the entry is not active yet
 * or declares no volatile fields).
 *
 * dsh 0.1.7 拆掉了 `settings.get(ns)`：SettingsForms 只剩 describe / update /
 * replace / mutate / writable，旧调用直接抛 "settings.get is not a function"，
 * 插件的整轮对账因此静默失效（路由模型清单不再跟随上游改名）。descriptor.value
 * 是 schema 投影后的活配置——llm-pi-ai 的 Config 是 `z.object({ providers:
 * z.dict(profile).default({}).volatile() })`，而 projectForm 对 dict 节点
 * 原样返回（只有 type === "object" 才逐字段投影），所以 value 就是完整的
 * `{ providers: {...} }`，与旧 get 读到的 config 等价。
 */
export function describeEntry(settings) {
	const descriptors = typeof settings.describe === "function" ? settings.describe() : [];
	const found = descriptors.find((descriptor) => descriptor.ns === NS);
	return found === undefined ? undefined : found;
}

/**
 * Read the route's configured models, verbatim.
 *
 * Deliberately *not* normalized here: `normalizeEntry` fills the capability
 * defaults, and `reconcile` has to be able to tell "the settings snapshot
 * never declared `reasoningEfforts`" (repair it, and say so) from "it already
 * did" (leave it alone). Normalizing on read erases that distinction — the
 * earlier relay copy passed its options here while its own comment said not
 * to, so its `repaired` report was always empty *and* the healing write never
 * happened. Reconcile owns normalization, exactly once, on the way out.
 */
export function readRouteModels(settings, route) {
	const descriptor = describeEntry(settings);
	const section = descriptor === undefined ? undefined : descriptor.value;
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
			.map((m) => ({ ...m }))
		: [];
	return { exists: true, models };
}

/** Read the namespace's current revision for optimistic writes. */
export function describeRevision(settings) {
	const found = describeEntry(settings);
	return found === undefined ? undefined : found.revision;
}

/**
 * Interrogate the live listing through the llm-pi-ai discovery contract.
 * Provider id is intentionally omitted so the catalog short-circuit is skipped
 * and the network branch runs with our supplied credential.
 */
export async function discoverLive(ctx, opts) {
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
 * Ask pi-ai's installed catalog which ids this route already serves.
 *
 * Why this must be consulted before adopting anything. A `models` list in the
 * profile patch **replaces** the served catalog instead of extending it
 * (dsh-llm-pi-ai: `sets modelOverrides for "<id>" beside a models list; models
 * already replaces the served catalog`). The `opencode-go` route declares no
 * models, so the catalog is what serves it — with real capacities, reasoning
 * levels and per-model compat. Adopting a catalog id would therefore swap that
 * metadata for this plugin's conservative defaults (128k / 32k / text-only),
 * and adoption is add-only, so the downgrade would be permanent.
 *
 * `discoverModels` short-circuits to the catalog exactly when a provider id is
 * given, and with no baseURL a route the catalog does not describe fails
 * deterministically before any request — so this probe never touches the
 * network and a non-catalog route simply yields an empty set.
 */
export async function discoverCatalogIds(ctx, opts) {
	const llm = ctx.get("llm");
	if (llm === undefined || typeof llm.discoverModels !== "function") return new Set();
	let models;
	try {
		models = await llm.discoverModels(NS, { provider: opts.route });
	} catch {
		// pi-ai ships no catalog for this route: nothing to protect.
		return new Set();
	}
	return new Set(
		(Array.isArray(models) ? models : [])
			.map((entry) => (typeof entry?.id === "string" ? entry.id : ""))
			.filter((id) => id.length > 0)
	);
}

function compatOf(entry) {
	return entry !== undefined && typeof entry.compat === "object" ? entry.compat : undefined;
}

/**
 * Merge the live listing into the configured models under the plugin's policy.
 *
 * Entries outside `opts.includePrefixes` are the user's business: kept
 * verbatim, never dropped, never overwritten.
 *
 * @param existing - the route's configured models.
 * @param live - the endpoint's advertised listing.
 * @param opts - resolved plugin options (mode, scope, capability defaults).
 * @param catalogIds - ids the installed catalog serves (add-only mode only).
 * @returns `{ merged, added, dropped, repaired }`; the latter three are id lists.
 */
export function reconcile(existing, live, opts, catalogIds) {
	const addOnly = opts.mode === "add-only";
	const liveIds = new Set(
		live.map((entry) => (typeof entry?.id === "string" ? entry.id : "")).filter(Boolean)
	);
	const liveById = new Map(
		live
			.filter((entry) => typeof entry?.id === "string" && entry.id.length > 0)
			.map((entry) => [entry.id, entry])
	);
	const merged = [];
	const seen = new Set();
	const added = [];
	const dropped = [];
	const repaired = [];

	for (const entry of existing) {
		if (!inScope(entry.id, opts.includePrefixes)) {
			merged.push(entry);
			seen.add(entry.id);
			continue;
		}
		// Add-only never prunes: a listing that omits a configured id says
		// nothing about whether the route still serves it.
		if (!addOnly && !liveIds.has(entry.id)) {
			dropped.push(entry.id);
			continue;
		}
		const before = entry.reasoningEfforts;
		// Configured fields win (a deliberate `reasoningEfforts: false` opt-out
		// must survive); the listing only fills what the entry does not declare.
		const kept = normalizeEntry({ ...capabilityOf(liveById.get(entry.id)), ...entry }, entry.id, opts);
		if (before === undefined && kept.reasoningEfforts !== undefined) repaired.push(entry.id);
		merged.push(kept);
		seen.add(entry.id);
	}

	for (const liveEntry of live) {
		const id = typeof liveEntry?.id === "string" ? liveEntry.id.trim() : "";
		if (id.length === 0 || seen.has(id) || !inScope(id, opts.includePrefixes)) continue;
		// A catalog id keeps the catalog's own metadata; see discoverCatalogIds.
		if (catalogIds !== undefined && catalogIds.has(id)) continue;
		seen.add(id);
		const adopted = normalizeEntry(
			{
				id,
				...(typeof liveEntry.name === "string" && liveEntry.name.trim().length > 0
					? { name: liveEntry.name.trim() }
					: {}),
				...(hasCapacity(liveEntry.contextWindow) ? { contextWindow: liveEntry.contextWindow } : {}),
				...(hasCapacity(liveEntry.maxTokens) ? { maxTokens: liveEntry.maxTokens } : {}),
				...capabilityOf(liveEntry),
			},
			id,
			opts
		);
		if (compatOf(adopted) === undefined) adopted.compat = { ...NEW_MODEL_COMPAT };
		merged.push(adopted);
		added.push(id);
	}

	return { merged, added, dropped, repaired };
}

/** One full sync pass. Never throws; returns a plain report for the log. */
export async function syncOnce(ctx, opts) {
	let live;
	try {
		live = typeof opts.discover === "function" ? await opts.discover(ctx, opts) : await discoverLive(ctx, opts);
	} catch (error) {
		return { ok: false, reason: `discovery failed: ${messageOf(error)}` };
	}
	// An empty (or unreadable) listing must not mutate the route: in reconcile
	// mode it would read as "the gateway dropped every model", and in add-only
	// mode it carries nothing to adopt.
	if (live.length === 0) {
		return { ok: false, reason: "live listing empty; leaving route untouched" };
	}
	const catalogIds = opts.deferToCatalog ? await discoverCatalogIds(ctx, opts) : undefined;

	// 同一个命名空间有多个写者（另外两个 autosync、dsh-tap 的宿主镜像、设置页），
	// 所以每一轮都重新活取 settings 实例并重读路由，而不是用 pass 开头那份快照：
	//   1. 每次写入都会重载 profile，Settings 实例随之被替换。抓着旧引用（连带旧
	//      revision）重试只会一直报 "expected revision N, now N+1" —— 2026-09-30
	//      实测 opencode 那一轮就是这么死的；dsh-tap 的 host-config.js 也记过同一
	//      个坑（"实测：expected revision 5, now 6，三次全败"）。
	//   2. 用旧快照算 merged，会把别人刚写进去的改动覆盖回去 —— 同一轮实测：
	//      runinfra 已同步的清单被后写的快照覆盖回同步前那 6 条。
	for (let attempt = 0; attempt < WRITE_ATTEMPTS; attempt++) {
		const services = ctx.get("settings");
		if (services === undefined) {
			return { ok: false, reason: "settings service unavailable" };
		}
		const { exists, models: existing } = readRouteModels(services, opts.route);
		if (exists === false) {
			return { ok: false, reason: `route "${opts.route}" not declared under ${NS}.providers` };
		}
		const { merged, added, dropped, repaired } = reconcile(existing, live, opts, catalogIds);
		if (added.length === 0 && dropped.length === 0 && repaired.length === 0) {
			return {
				ok: true,
				addedCount: 0,
				droppedCount: 0,
				repairedCount: 0,
				route: opts.route,
				...await publishOnce(opts, live, merged),
			};
		}
		if (services.writable === false) return { ok: false, reason: "settings provider is read-only" };
		try {
			await services.update(
				NS,
				{ providers: { [opts.route]: { models: merged } } },
				describeRevision(services)
			);
			return {
				ok: true,
				addedCount: added.length,
				added,
				droppedCount: dropped.length,
				dropped,
				repairedCount: repaired.length,
				repaired,
				route: opts.route,
				...await publishOnce(opts, live, merged),
			};
		} catch (error) {
			if (codeOf(error) !== "SETTINGS_CONFLICT") {
				return { ok: false, reason: `write failed: ${messageOf(error)}` };
			}
		}
	}
	return { ok: false, reason: `write failed: SETTINGS_CONFLICT after ${WRITE_ATTEMPTS} attempts` };
}

/**
 * Hand the reconciled catalog to the descriptor's publisher, if it declares
 * one. Runs on every pass that leaves the route consistent — including a pass
 * that changed nothing, so a missing/stale published file heals without
 * waiting for the next gateway rename. A publish failure never fails the sync:
 * the route in dsh is the primary artifact, the published file the copy.
 */
async function publishOnce(opts, live, merged) {
	if (typeof opts.publish !== "function") return {};
	try {
		await opts.publish({ opts, live, merged });
		return {};
	} catch (error) {
		return { publishError: messageOf(error) };
	}
}

/**
 * Resolve the plugin row's config over the descriptor's defaults.
 *
 * Both optional narrowings (`includePrefixes`, `defaultReasoningEfforts`) are
 * declared by the row in `pkgs/dsh-local/default.nix` and may be overridden
 * there; the descriptor carries the fallback so a row that omits them behaves
 * like the plugin it replaces.
 */
export function resolveOptions(config, spec) {
	const configuredPrefixes = config?.includePrefixes;
	const prefixes = Array.isArray(configuredPrefixes)
		? configuredPrefixes.filter((prefix) => typeof prefix === "string" && prefix.length > 0)
		: spec.includePrefixes ?? [];
	const configuredEfforts = config?.defaultReasoningEfforts;
	const efforts =
		configuredEfforts !== undefined && configuredEfforts !== null && typeof configuredEfforts === "object"
			? configuredEfforts
			: spec.defaultReasoningEfforts ?? null;
	return {
		route: config?.route ?? spec.route,
		baseURL: config?.baseURL ?? spec.baseURL,
		api: config?.api ?? spec.api,
		apiKeyEnv: config?.apiKeyEnv ?? spec.apiKeyEnv,
		intervalMs: Number.isFinite(config?.intervalMs) ? config.intervalMs : DEFAULT_INTERVAL_MS,
		mode: spec.mode,
		deferToCatalog: spec.deferToCatalog === true,
		includePrefixes: prefixes,
		...(efforts === undefined || efforts === null ? {} : { defaultReasoningEfforts: { ...efforts } }),
		...(typeof spec.discover === "function" ? { discover: spec.discover } : {}),
		...(typeof spec.publish === "function" ? { publish: spec.publish } : {}),
	};
}

/**
 * Build one autosync plugin from its descriptor.
 *
 * The plugin is host-only and imports nothing outside the module system: every
 * capability is resolved lazily through `ctx.get`. Startup/interval overlap is
 * prevented with a simple in-flight flag.
 *
 * The settings service is a hard dependency: `ctx.inject(["settings"], ...)`
 * defers activation until the provider has installed it, so the first pass
 * still runs at startup but never races it (a fixed 2s timer did race it, and
 * the failed pass then waited a full interval). The injected child fiber also
 * owns both timers, so losing the settings service disposes them and regaining
 * it re-arms them.
 *
 * @param spec - `{ name, mode, route, baseURL, api, apiKeyEnv, deferToCatalog?,
 *                 includePrefixes?, defaultReasoningEfforts?, discover?, publish? }`.
 * @returns the cordis plugin exports (`name`, `inject`, `apply`).
 */
export function createAutoSyncPlugin(spec) {
	const name = spec.name;
	const inject = ["timer"];

	async function apply(ctx, config) {
		const opts = resolveOptions(config, spec);
		// Guard against overlapping runs that would each re-read and rewrite.
		let running = false;
		const run = async (runCtx) => {
			if (running) return;
			running = true;
			try {
				const report = await syncOnce(runCtx, opts);
				console.log(`[${name}] ${JSON.stringify(report)}`);
			} catch (error) {
				console.error(`[${name}] ${messageOf(error)}`);
			} finally {
				running = false;
			}
		};
		ctx.inject(["settings"], (settingsCtx) => {
			// First pass shortly after activation (lets the llm service settle),
			// then a periodic pass.
			settingsCtx.timeout(() => void run(settingsCtx), 2000);
			settingsCtx.effect(
				() => settingsCtx.interval(() => void run(settingsCtx), opts.intervalMs),
				`${name}.interval`
			);
		});
	}

	return { name, inject, apply };
}
//#endregion
