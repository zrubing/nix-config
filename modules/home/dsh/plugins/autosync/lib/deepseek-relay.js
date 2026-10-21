//#region lib/deepseek-relay.js
/**
 * deepseek-relay — reconcile the deepseek-relay route against the live relay
 * `/v1/models` listing.
 *
 * The route is a plain openai-completions gateway (non-catalog), so its
 * Nix-managed model list goes stale the moment the relay renames or ships a
 * model (2026-09-10: the whole catalog collapsed to `deepseek-flash`,
 * retiring v4-flash / v4-flash-vision-exp / v4-pro / v4.1-flash). The relay's
 * `/v1/models` is authoritative for *which ids exist*, so this plugin
 * reconciles ids: keep in-scope ids still advertised (with their configured
 * compat/reasoningEfforts/capacity), drop in-scope ids the relay no longer
 * lists.
 *
 * Adoption needs a capacity before it can happen (2026-10-20): the relay's
 * listing discloses ids only — it has no capacities, no reasoning levels, and
 * its `/model/info` is a web page, not an API — so a newly advertised id is
 * reported as `unresolved` rather than written with a guessed figure. A new
 * relay model therefore lands in `modules/home/llm-routes/routes.nix` first
 * (the route's single source), and the next pass picks the entry up.
 *
 * Two deliberate narrowings over the unscoped runinfra policy:
 *
 *   1. Scope. The relay advertises far more than the DeepSeek family, while
 *      this route is hand-curated; `includePrefixes` (default `["deepseek-"]`,
 *      overridable per row) confines adoption/dropping to those ids. Entries
 *      outside the scope are left exactly as configured — never dropped, never
 *      overwritten.
 *   2. Capability defaults. A model without `reasoningEfforts` reports *no*
 *      reasoning capability to the harness, which silently removes the
 *      thinking-effort control from the model picker (exactly the regression
 *      seen after the rename above). `defaultReasoningEfforts` is therefore
 *      applied to every in-scope entry that does not declare the field (so a
 *      settings snapshot written before this option existed heals), while an
 *      explicit `reasoningEfforts: false` is respected as a deliberate opt-out.
 *
 * See ./plugin.js for the shared skeleton and the settings-write contract.
 */
import { createAutoSyncPlugin } from "./plugin.js";

/** 路由事实：既构造运行期插件，也供 lib/cli.js 复用同一份（不复制一份）。 */
export const spec = {
	name: "deepseek-relay-autosync",
	mode: "reconcile",
	route: "deepseek-relay",
	// 端点由行配置提供（clan secret，`!!js process.env.DEEPSEEK_RELAY_BASE_URL`）。
	// 这里**不放兜底**：兜底会把地址固化进 git，并让「这次请求打到哪」无法从
	// 配置判断——2026-10-21 实测就是它让 CLI 在 env 缺失时静默打到了那个地址。
	api: "openai-completions",
	apiKeyEnv: "DEEPSEEK_RELAY_API_KEY",
	includePrefixes: ["deepseek-"],
};

export const { name, inject, apply } = createAutoSyncPlugin(spec);
//#endregion
