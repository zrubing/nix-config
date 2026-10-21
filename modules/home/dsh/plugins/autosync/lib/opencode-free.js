//#region lib/opencode-free.js
/**
 * opencode-free — the free tier the Go endpoint actually serves.
 *
 * ## Why a route of its own
 *
 * `opencode-go` is catalog-backed: the picker's list *is* pi-ai's static
 * catalog, and a `models` list in that route **replaces** the catalog instead
 * of extending it. Writing the free ids there would therefore delete the thirty
 * catalog models (and their per-model compat) — which is why that descriptor is
 * report-only. This route is not catalog-backed: nothing else serves it, so its
 * `models` list is the single owner and the live listing can own it outright.
 *
 * The scope is the `-free` suffix, so the listing's paid ids (the same 37 the
 * `opencode-go` route already serves from the catalog) never get imported here.
 *
 * ## Facts (2026-10-20)
 *
 * `GET /inference/go/v1/models` answers 37 ids, 3 of them free
 * (`minimax-m3.1-flash-free`, `longcat-2.5-preview-free`, `beam-free`); all
 * three answer 200 through `chat/completions` once `x-opencode-session` is
 * present. The zen endpoint's free tier — `deepseek-v4.1-flash-free` among them
 * — is refused outside the OpenCode client with `403 FreeTierError`, and the Go
 * endpoint answers `400 Model is unavailable` for those ids, so they cannot
 * appear here no matter what the catalog says.
 *
 * ## Ownership
 *
 * `reconcile`: the listing is authoritative for which free ids exist, so a
 * retired free model is dropped instead of lingering and 400-ing on selection.
 * Capacity comes from models.dev (`opencode` describes the free tier; the
 * `opencode-go` slice also carries some of them), never from a default. An id
 * the catalog does not describe is left unresolved and reported — it is not
 * written with invented numbers.
 */
import { capabilityMap, loadCatalog, providerSlice } from "./catalog.js";
import { createAutoSyncPlugin } from "./plugin.js";

/**
 * models.dev provider ids, most exact first. The free tier lives in the
 * pay-as-you-go `opencode` slice; `opencode-go` is consulted second for the ids
 * it happens to describe.
 */
export const CATALOG_PROVIDER_IDS = ["opencode", "opencode-go"];

export async function capabilitySource(live) {
	const catalog = await loadCatalog();
	if (catalog.stale === true) {
		console.warn(
			`[opencode-free-autosync] models.dev unreachable (${catalog.reason ?? "unknown"}); using cached copy from ${new Date(catalog.fetchedAt).toISOString()}`
		);
	}
	const provider = providerSlice(catalog.providers, CATALOG_PROVIDER_IDS);
	if (provider === undefined) {
		throw new Error(`models.dev declares none of: ${CATALOG_PROVIDER_IDS.join(", ")}`);
	}
	const known = capabilityMap(provider);
	// The second slice only fills the gaps the first one leaves.
	for (const fallbackId of CATALOG_PROVIDER_IDS.slice(1)) {
		const fallback = providerSlice(catalog.providers, [fallbackId]);
		if (fallback === undefined) continue;
		for (const [id, capability] of capabilityMap(fallback)) {
			if (!known.has(id)) known.set(id, capability);
		}
	}
	const missing = live
		.map((entry) => (typeof entry?.id === "string" ? entry.id : ""))
		// Only this route's scope: the listing also carries the paid ids the
		// catalog route serves, and warning about those here would be noise.
		.filter((id) => id.length > 0 && id.endsWith("-free") && !known.has(id));
	if (missing.length > 0) {
		console.warn(
			`[opencode-free-autosync] ${missing.length} free id(s) the listing serves but models.dev does not describe: ${missing.join(", ")}`
		);
	}
	return known;
}

/** 路由事实：既构造运行期插件，也供 lib/cli.js 复用同一份（不复制一份）。 */
export const spec = {
	name: "opencode-free-autosync",
	mode: "reconcile",
	route: "opencode-free",
	// 与 opencode-go 同一个网关、同一把 key：只是把 `-free` 这一档分出来，
	// 让它拥有自己的 models 列表（opencode-go 的那份由 pi-ai catalog 提供）。
	baseURL: "https://opencode.ai/inference/go/v1",
	api: "openai-completions",
	apiKeyEnv: "OPENCODE_API_KEY",
	includeSuffixes: ["-free"],
	capabilitySource,
};

export const { name, inject, apply } = createAutoSyncPlugin(spec);
//#endregion
