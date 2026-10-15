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
 * its real capacities / reasoning levels / compat for this plugin's
 * conservative defaults, permanently.
 *
 * See ./plugin.js for the shared skeleton and the settings-write contract.
 */
import { createAutoSyncPlugin } from "./plugin.js";

export const { name, inject, apply } = createAutoSyncPlugin({
	name: "opencode-autosync",
	mode: "add-only",
	deferToCatalog: true,
	route: "opencode-go",
	// 官方文档（opencode.ai/v2/docs/console/go）的规范拼写是 /inference/go/v1；
	// 旧拼写 /zen/go/v1 仍是活的别名（2026-10-14 实测两者 GET /models 返回同一份
	// 40 条清单），用规范写法以免别名撤销时静默失效。
	baseURL: "https://opencode.ai/inference/go/v1",
	api: "openai-completions",
	apiKeyEnv: "OPENCODE_API_KEY",
});
//#endregion
