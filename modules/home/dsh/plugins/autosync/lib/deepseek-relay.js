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
 * compat/reasoningEfforts/capacity), adopt newly advertised ids, drop in-scope
 * ids the relay no longer lists.
 *
 * Two deliberate narrowings over the unscoped runinfra policy:
 *
 *   1. Scope. The relay advertises far more than the DeepSeek family, while
 *      this route is hand-curated; `includePrefixes` (default `["deepseek-"]`,
 *      overridable per row) confines adoption/dropping to those ids. Entries
 *      outside the scope are left exactly as configured — never dropped, never
 *      overwritten.
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
 * See ./plugin.js for the shared skeleton and the settings-write contract.
 */
import { createAutoSyncPlugin } from "./plugin.js";

export const { name, inject, apply } = createAutoSyncPlugin({
	name: "deepseek-relay-autosync",
	mode: "reconcile",
	route: "deepseek-relay",
	baseURL: "https://enterprise.hallucodex.chat/v1",
	api: "openai-completions",
	apiKeyEnv: "DEEPSEEK_RELAY_API_KEY",
	includePrefixes: ["deepseek-"],
});
//#endregion
