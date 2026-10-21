//#region lib/runinfra.js
/**
 * runinfra — reconcile the RunInfra route against the live
 * `api.runinfra.ai/v1/models` listing, and publish the reconciled catalog for
 * the pi provider extension.
 *
 * ## One syncer, two consumers
 *
 * runinfra used to be synced twice: this plugin reconciled dsh, while pi ran
 * the upstream `monotykamary/pi-runinfra-provider` extension with a
 * stale-while-revalidate merge of its embedded `models.json`. The two
 * disagreed on the one thing that matters — the id set. The embedded list is
 * a snapshot; its merge never dropped an id, so after the gateway renamed
 * `deepseek-v4-flash` → `deepseek-v4-1-flash` pi still offered the old id
 * (plus `deepseek-v4-pro`, `qwen3-8-2-4t-a95b`), while dsh had already
 * converged on the live five. 2026-09-30 the extension was retired: dsh is
 * the only syncer, and it publishes what pi registers.
 *
 *   ~/.cache/llm/runinfra-models.json
 *
 * is the hand-off. Schema: an envelope `{ version, provider, baseURL, source,
 * syncedAt, models }` whose `models` are pi provider entries; pi reads it with
 * `modules/home/pi/extensions/runinfra/index.ts`. The gateway is the single
 * source of truth; the Nix seed in modules/home/dsh is a bootstrap the first
 * pass reconciles away.
 *
 * ## Policy
 *
 * Strict reconcile, unscoped: a single-protocol gateway's `/v1/models` is
 * authoritative, so ids it no longer advertises are dropped. Config entries
 * that survive keep their curated `compat` / `reasoningEfforts` (patch.json,
 * manual settings edits); a capability the entry does not declare is filled
 * from the listing (see `discover`). Newly adopted ids
 * additionally get the shared gateway-safe compat — the gateway 400s the
 * `developer` role — and the listing's own capacities and pricing.
 *
 * `discover` reads the raw payload rather than going through
 * `ctx.llm.discoverModels` because the llm-pi-ai discovery contract keeps only
 * id / name / capacities. The published pi entries need the gateway's own
 * `reasoning_efforts`, `input_modalities` and `pricing` too; mapping them onto
 * pi's thinking levels here (not in pi) keeps one mapping for both consumers.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createAutoSyncPlugin } from "./plugin.js";

const PROVIDER_ID = "runinfra";
const BASE_URL = "https://api.runinfra.ai/v1";
const CATALOG_VERSION = 1;
const FETCH_TIMEOUT_MS = 8000;
/** pi's thinking levels, ascending; index-comparable with EFFORT_ORDER. */
const PI_THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
/** Provider-side effort names in ascending order ("none" = thinking off). */
const EFFORT_ORDER = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];
/**
 * pi compat keys this projection may carry. dsh's schema is a superset (it
 * also has chatTemplateArgs), and pi rejects nothing but ignores unknown keys —
 * filtering keeps the published file exactly the intersection.
 */
const PI_COMPAT_KEYS = [
	"supportsDeveloperRole",
	"supportsStore",
	"maxTokensField",
	"thinkingFormat",
	"supportsReasoningEffort",
	"requiresReasoningContentOnAssistantMessages",
	"chatTemplateKwargs",
];

export function messageOf(error) {
	if (error instanceof Error) return error.message;
	if (error !== null && typeof error === "object" && typeof error.message === "string") return error.message;
	return String(error);
}

/**
 * Where the published catalog lives. Deliberately a fixed `~/.cache` path
 * rather than an XDG lookup: the dsh-web systemd unit and the interactive pi
 * shell each resolve environment differently, and a cache dir that disagrees
 * between writer and reader would silently strand pi on a stale catalog.
 */
export function catalogFilePath(env = process.env) {
	const home = typeof env.HOME === "string" && env.HOME.length > 0 ? env.HOME : os.homedir();
	return path.join(home, ".cache", "llm", "runinfra-models.json");
}

function firstPositiveInt(...values) {
	for (const value of values) {
		if (typeof value === "number" && Number.isFinite(value) && value > 0) return Math.trunc(value);
	}
	return undefined;
}

function priceOf(value) {
	return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0;
}

function modalitiesOf(reported) {
	if (!Array.isArray(reported)) return undefined;
	const mapped = reported.filter((entry) => entry === "text" || entry === "image");
	return mapped.length > 0 ? mapped : undefined;
}

/**
 * Map the gateway's advertised effort names onto pi's thinking levels.
 *
 * Every level resolves to the highest effort the gateway offers at or below
 * it (so a gateway offering `low`/`high` maps `medium` → `low`), levels below
 * the smallest offered positive effort clamp up to it, and `off` maps to
 * `none` only when the gateway actually offers it. A level with nothing below
 * it is `null` = unsupported, pi's three-state semantics.
 *
 * @param reported - the listing's `reasoning_efforts` names.
 * @returns a pi `thinkingLevelMap` (all seven levels, `null` = unsupported).
 */
export function thinkingLevelMapFromEfforts(reported) {
	const offered = new Set(
		(Array.isArray(reported) ? reported : []).filter((name) => EFFORT_ORDER.includes(name))
	);
	const positive = EFFORT_ORDER.filter((name) => name !== "none" && offered.has(name));
	const map = { off: offered.has("none") ? "none" : null };
	for (const level of PI_THINKING_LEVELS) {
		if (level === "off") continue;
		const index = EFFORT_ORDER.indexOf(level);
		let value = null;
		for (let candidate = index; candidate > 0; candidate--) {
			if (offered.has(EFFORT_ORDER[candidate])) {
				value = EFFORT_ORDER[candidate];
				break;
			}
		}
		map[level] = value ?? positive[0] ?? null;
	}
	return map;
}

function hasThinking(thinkingLevelMap) {
	return PI_THINKING_LEVELS.some((level) => level !== "off" && thinkingLevelMap[level] !== null);
}

/**
 * Read the gateway listing. Returns entries in the shape the shared
 * `reconcile` consumes (id / name / capacities) plus the capability fields it
 * copies onto entries that lack them (input / reasoningEfforts) and the
 * pricing the publisher needs.
 */
export async function discoverLiveListing(_ctx, opts) {
	const env = typeof process !== "undefined" && process.env ? process.env : {};
	const apiKey = env[opts.apiKeyEnv];
	const url = `${String(opts.baseURL).replace(/\/+$/, "")}/models`;
	const response = await fetch(url, {
		headers: {
			accept: "application/json",
			...(typeof apiKey === "string" && apiKey.length > 0 ? { authorization: `Bearer ${apiKey}` } : {}),
		},
		signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
	});
	if (!response.ok) throw new Error(`${url} answered ${response.status}`);
	const payload = await response.json();
	const listed = Array.isArray(payload)
		? payload
		: Array.isArray(payload?.data)
			? payload.data
			: payload?.models !== null && typeof payload?.models === "object" && !Array.isArray(payload.models)
				? Object.entries(payload.models).map(([id, raw]) => ({ ...(raw ?? {}), id }))
				: [];
	return listed
		.filter((entry) => entry !== null && typeof entry === "object" && typeof entry.id === "string" && entry.id.length > 0)
		.map((entry) => {
			const thinkingLevelMap = thinkingLevelMapFromEfforts(entry.reasoning_efforts);
			const displayName = typeof entry.display_name === "string" ? entry.display_name.trim() : "";
			const name = typeof entry.name === "string" ? entry.name.trim() : "";
			return {
				id: entry.id,
				name: displayName.length > 0 ? displayName : name.length > 0 ? name : entry.id,
				...(firstPositiveInt(entry.context_window, entry.context_length, entry.max_input_tokens) === undefined
					? {}
					: { contextWindow: firstPositiveInt(entry.context_window, entry.context_length, entry.max_input_tokens) }),
				...(firstPositiveInt(entry.max_output_tokens, entry.max_completion_tokens, entry.maxTokens) === undefined
					? {}
					: { maxTokens: firstPositiveInt(entry.max_output_tokens, entry.max_completion_tokens, entry.maxTokens) }),
				...(modalitiesOf(entry.input_modalities) === undefined ? {} : { input: modalitiesOf(entry.input_modalities) }),
				...(hasThinking(thinkingLevelMap) ? { reasoningEfforts: thinkingLevelMap } : {}),
				cost: {
					input: priceOf(entry.pricing?.input),
					output: priceOf(entry.pricing?.output),
					cacheRead: priceOf(entry.cached_input_price_usd_per_mtok ?? entry.cached_input_price),
					cacheWrite: 0,
				},
			};
		});
}

/** Project one reconciled dsh entry into a pi provider model entry. */
export function toPiModel(entry, liveEntry) {
	const declared =
		entry.reasoningEfforts !== null && typeof entry.reasoningEfforts === "object" ? entry.reasoningEfforts : undefined;
	const thinkingLevelMap = {};
	for (const level of PI_THINKING_LEVELS) {
		const value = declared?.[level];
		thinkingLevelMap[level] = typeof value === "string" ? value : null;
	}
	const model = {
		id: entry.id,
		name: entry.name,
		reasoning: hasThinking(thinkingLevelMap),
		input: Array.isArray(entry.input) && entry.input.length > 0 ? [...entry.input] : ["text"],
		cost: liveEntry?.cost ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow: entry.contextWindow,
		maxTokens: entry.maxTokens,
	};
	if (model.reasoning) model.thinkingLevelMap = thinkingLevelMap;
	const compat = Object.fromEntries(
		PI_COMPAT_KEYS.filter((key) => entry.compat !== undefined && entry.compat !== null && entry.compat[key] !== undefined).map(
			(key) => [key, entry.compat[key]]
		)
	);
	if (Object.keys(compat).length > 0) model.compat = compat;
	return model;
}

/**
 * Publish the reconciled catalog for the pi provider extension. Atomic write
 * (tmp + rename): pi may read the file at any moment, and a half-written
 * catalog would register a truncated model list.
 */
export function publishCatalog({ live, merged }) {
	const liveById = new Map(live.map((entry) => [entry.id, entry]));
	const models = merged.map((entry) => toPiModel(entry, liveById.get(entry.id)));
	const file = catalogFilePath();
	const payload = {
		version: CATALOG_VERSION,
		provider: PROVIDER_ID,
		baseURL: BASE_URL,
		source: "dsh-autosync/runinfra",
		syncedAt: new Date().toISOString(),
		models,
	};
	fs.mkdirSync(path.dirname(file), { recursive: true });
	const temporary = `${file}.tmp-${process.pid}`;
	fs.writeFileSync(temporary, JSON.stringify(payload, null, 2) + "\n");
	fs.renameSync(temporary, file);
}

/** 路由事实：既构造运行期插件，也供 lib/cli.js 复用同一份（不复制一份）。 */
export const spec = {
	name: "runinfra-autosync",
	mode: "reconcile",
	route: "runinfra",
	baseURL: BASE_URL,
	api: "openai-completions",
	apiKeyEnv: "RUNINFRA_GATEWAY_KEY",
	discover: discoverLiveListing,
	publish: publishCatalog,
};

export const { name, inject, apply } = createAutoSyncPlugin(spec);
//#endregion
