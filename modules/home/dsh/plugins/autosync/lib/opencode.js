//#region lib/opencode.js
/**
 * opencode-go — add-only discovery of the live opencode.ai Go-tier listing.
 *
 * `opencode-go` is a pi-ai *catalog* provider, so the on-demand
 * `dsh-opencode-models` plugin (and the Models page "fetch available models"
 * action) reconcile it against pi-ai's static catalog, never against
 * opencode.ai — and they would flag every manually-added model outside that
 * catalog as "stale". This plugin asks the endpoint itself instead.
 *
 * Policy: add-only, and catalog ids are left to the catalog. The route is
 * mixed-protocol (`anthropic-messages` and `openai-completions` ids share it),
 * so an omitted id must never be pruned, and a `models` list replaces the
 * served catalog rather than extending it — adopting a catalog id would trade
 * its real capacities / reasoning levels / compat for whatever the listing
 * disclosed, permanently.
 *
 * ## Where the figures come from
 *
 * `/inference/go/v1/models` answers ids only (`id / object / created /
 * owned_by`; `?detailed` is ignored), and it is filtered by the workspace's
 * per-model toggles in the opencode console (`/console/<workspace>/models`).
 * The capability therefore comes from `models.dev` — the catalog opencode's own
 * client is generated from — through `./catalog.js`.
 *
 * ## Report-only, deliberately
 *
 * The route's served list is pi-ai's static catalog, and a `models` list
 * *replaces* it. Materializing what this pass saw would therefore (a) drop
 * every catalog id the listing did not mention and (b) import ids the workspace
 * may not have toggled on — the live listing and `models.dev` disagree in both
 * directions (2026-10-20: 7 ids served but uncatalogued, 3 catalogued but not
 * served). So this descriptor writes nothing: it logs the ids the catalog does
 * not describe, and the model list keeps exactly one owner, the catalog.
 *
 * See ./plugin.js for the shared skeleton and the settings-write contract.
 */
import { capabilityMap, loadCatalog, providerSlice } from "./catalog.js";
import { createAutoSyncPlugin } from "./plugin.js";

/**
 * models.dev provider ids, most exact first. `opencode-go` is the Go tier;
 * `opencode` is the pay-as-you-go family the same client exposes, kept as a
 * second anchor in case the tier is folded back into it upstream.
 */
export const CATALOG_PROVIDER_IDS = ["opencode-go", "opencode"];

export async function capabilitySource(live) {
	const catalog = await loadCatalog();
	if (catalog.stale === true) {
		console.warn(
			`[opencode-autosync] models.dev unreachable (${catalog.reason ?? "unknown"}); using cached copy from ${new Date(catalog.fetchedAt).toISOString()}`
		);
	}
	const provider = providerSlice(catalog.providers, CATALOG_PROVIDER_IDS);
	if (provider === undefined) {
		throw new Error(`models.dev declares none of: ${CATALOG_PROVIDER_IDS.join(", ")}`);
	}
	const known = capabilityMap(provider);
	const missing = live
		.map((entry) => (typeof entry?.id === "string" ? entry.id : ""))
		.filter((id) => id.length > 0 && !known.has(id));
	if (missing.length > 0) {
		console.warn(
			`[opencode-autosync] ${missing.length} id(s) the listing serves but ${provider.id} does not describe: ${missing.join(", ")}`
		);
	}
	return known;
}

export const { name, inject, apply } = createAutoSyncPlugin({
	name: "opencode-autosync",
	mode: "add-only",
	deferToCatalog: true,
	reportOnly: true,
	route: "opencode-go",
	// 官方文档（opencode.ai/v2/docs/console/go）的规范拼写是 /inference/go/v1；
	// 旧拼写 /zen/go/v1 仍是活的别名（2026-10-14 实测两者 GET /models 返回同一份
	// 40 条清单，2026-10-20 复测 37 条），用规范写法以免别名撤销时静默失效。
	baseURL: "https://opencode.ai/inference/go/v1",
	api: "openai-completions",
	apiKeyEnv: "OPENCODE_API_KEY",
	capabilitySource,
});
//#endregion
