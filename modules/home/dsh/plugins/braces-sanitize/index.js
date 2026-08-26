/**
 * dsh-braces-sanitize — neutralize unregistered {{...}} groups before render.
 *
 * Background: @deepseek-ai/dsh-system-prompt renders sections with strict
 * template interpolation; any complete {{name}} group whose name is not a
 * registered variable throws ("malformed prompt variable reference ... in
 * section tools:sdk") and fails the whole turn. External MCP servers ship
 * tool descriptions containing literal brace examples (apipost's
 * get_target_detail documents its env-var syntax as {{paramName}}), which
 * code-mode serializes into the tools:sdk section text verbatim.
 *
 * Fix strategy: listen on the system-prompt/assemble waterfall, run next()
 * first, then rewrite the authoritative assembly — replace every complete
 * {{name}} group whose name is NOT in assembly.variables with fullwidth
 * braces (｛｛name｝｝). Fullwidth keeps the example human/model-readable while
 * breaking the pair that the renderer would reject. Registered variables
 * ({{model}}, {{cwd}}, ...) keep their interpolation.
 *
 * Plugin shape follows @deepseek-ai/dsh-mcp-client: named exports, no
 * default export, async apply(ctx, config).
 */

/** Cordis plugin name used by loader diagnostics. */
const name = "mcp-braces-sanitize";

/**
 * Neutralize complete {{name}} groups not present in `known`.
 * A lone "{{" with no closing "}}" passes through the renderer verbatim, so
 * fullwidth substitution is sufficient to defuse it.
 */
function makeScrubber(known) {
	return (text) => text.replace(/\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}/g, (whole, varName) =>
		Object.prototype.hasOwnProperty.call(known, varName) ? whole : `\uFF5B\uFF5B${varName}\uFF5D\uFF5D`);
}

/**
 * @param ctx - plugin context (cordis).
 */
async function apply(ctx) {
	ctx.effect(
		() => ctx.on("system-prompt/assemble", async function (assembly, _context, next) {
			const result = await next();
			if (!result || typeof result !== "object") return result;
			const known = new Set(Object.keys(result.variables ?? {}));
			const scrub = makeScrubber(known);
			for (const section of result.sections ?? []) {
				if (typeof section?.text === "string" && section.text.includes("{{")) {
					section.text = scrub(section.text);
				}
			}
			for (const contextEntry of result.contexts ?? []) {
				if (typeof contextEntry?.text === "string" && contextEntry.text.includes("{{")) {
					contextEntry.text = scrub(contextEntry.text);
				}
			}
			return result;
		}),
		`${name}.assemble-listener`,
	);
}

export { apply, name };
