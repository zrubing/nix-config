// The `ast_grep` tool: structural code search and rewrite over ast-grep
// (tree-sitter AST patterns), exposed as a first-class model tool so the agent
// reaches for syntax-level matching instead of falling back to regex grep,
// and so pattern/rewrite never fight shell quoting. Search prints
// `file:line: code` matches; exit code 1 means "no matches" — a normal result
// rendered as `(no matches)`, never as a failure marker (>= 2 is a real CLI
// error). `rewrite` previews the structural replacement as a diff and only
// writes files with `apply: true` (ast-grep -U). Execution rides the same
// shell seam as the bash tool (ctx.shell.run), so sandbox policy, trusted
// shell-env, workdir resolution and timeouts behave identically.
//
// The preset row loads this file through a relative specifier (see
// tool-processes.js): the module travels with the preset, and nix builds the
// source beside a node_modules shim resolving the harness's own
// @deepseek-ai/* dependencies (modules/home/dsh: toolAstGrepPlugin). Both
// my-minimal and my-ptc deploy the same store product.
//
// Binary note: the command is `ast-grep`, never `sg` — on NixOS `sg` is
// shadow's set-group command, and the dsh-web service PATH puts
// /run/current-system/sw/bin (which has shadow's sg) ahead of the per-user
// bin that ships ast-grep.
//
// POSIX only: the command line is built with POSIX single-quote quoting for
// the bash executor; apply() refuses to mount on win32, where the preset's
// executor is pwsh and the quoting would be wrong.

import z from "@deepseek-ai/schemastery";
import { isAbsolute, resolve } from "node:path";
import { TOOL_ABORTED, defineTool } from "@deepseek-ai/dsh-tools";
import { HarnessError } from "@deepseek-ai/dsh-llm";
import { canonicalPath, sandboxDenialMarker } from "@deepseek-ai/dsh-sandbox";

const name = "tool-ast-grep";
const inject = ["tools", "shell", "shellEnv"];

/** Runtime configuration schema: the model-facing output budget. */
const Config = z.object({ maxOutputChars: z.number().default(16000) });

const BIN = "ast-grep";

/** POSIX single-quote one argv item (the executor runs bash -c). */
function shQuote(value) {
	return `'${String(value).replace(/'/g, "'\\''")}'`;
}

/** Resolve an explicit workdir against the session cwd (as dsh-tool-bash). */
function resolveWorkdir(modelWorkdir, exec, policyWorkspaceRoot) {
	const headerCwd = exec.agent?.session.header.cwd;
	const sessionCwd = policyWorkspaceRoot ?? (headerCwd === void 0 ? void 0 : canonicalPath(headerCwd));
	if (modelWorkdir === void 0) return sessionCwd;
	if (sessionCwd !== void 0 && !isAbsolute(modelWorkdir)) return resolve(sessionCwd, modelWorkdir);
	return modelWorkdir;
}

/** Append the executor truncation notice (with the full-output spill path). */
function streamText(output) {
	if (!output.truncated) return output.text;
	return `${output.text}\n[output truncated; full output: ${output.spillPath ?? "(unavailable)"}]`;
}

/** Shape one finished ast-grep run into the text the model sees. */
function renderResult(args, value, cap) {
	let body = streamText(value.stdout);
	const err = streamText(value.stderr);
	if (err.length > 0) {
		if (body.length > 0 && !body.endsWith("\n")) body += "\n";
		body += `[stderr]\n${err}`;
	}
	const markers = [];
	if (value.sandbox?.runnerFailed) markers.push("[sandbox: the sandbox runner itself failed — the command did not run; this is a sandbox problem, not a command failure]");
	else if (value.sandbox?.denied) markers.push(sandboxDenialMarker(value.sandbox.mode));
	if (value.timedOut) markers.push(`[timed out after ${value.timeoutMs}ms]`);
	if (value.signal !== null) markers.push(`[killed by signal: ${value.signal}]`);
	else if (value.exitCode !== null && value.exitCode >= 2) markers.push(`[exit code: ${value.exitCode}]`);
	// exit code 1 with empty output is ast-grep's "no matches" — a normal,
	// expected result; only >= 2 surfaces as a failure marker above.
	if (body.length === 0 && markers.length === 0) body = value.exitCode === 1 ? "(no matches)" : "(no output)";
	if (value.exitCode === 0 && args.rewrite !== void 0 && args.apply === true && !value.timedOut && value.signal === null) {
		markers.push("[files were modified on disk by ast-grep; re-read a file before editing it]");
	}
	if (body.length > cap) body = `${body.slice(0, cap)}\n[output truncated at ${cap} chars; narrow the search with paths/globs/lang/context]`;
	if (markers.length === 0) return body;
	if (!body.endsWith("\n")) body += "\n";
	return body + markers.join("\n");
}

function apply(ctx, config = {}) {
	if (process.platform === "win32") throw new Error("tool-ast-grep: POSIX shell quoting only; the win32 pwsh executor is unsupported");
	const maxOutputChars = config.maxOutputChars ?? 16000;
	const defaultMode = ctx.shell.sandboxMode;
	const sandboxPolicy = defaultMode === void 0 ? void 0 : ctx.get("sandboxPolicy");
	if (defaultMode !== void 0 && sandboxPolicy === void 0) throw new Error("tool-ast-grep: the mounted shell executor confines but ctx.sandboxPolicy is missing");
	/** Resolve the complete standing policy for this call when a confining executor is mounted. */
	const resolveSandboxPolicy = (exec) => sandboxPolicy?.resolve(exec.agent === void 0 ? {} : { session: exec.agent.session });

	ctx.tools.register(defineTool({
		name: "ast_grep",
		description: [
			"Structural code search and rewrite with ast-grep (tree-sitter AST patterns): matches syntax, not text, so it is far more precise than regex grep for code.",
			"Pattern syntax: `$NAME` captures one AST node, `$$$NAME` captures a sequence; everything else matches literally.",
			"Example: pattern `function $F($A) { return $$$B }` with lang `ts` finds every function declaration.",
			"Omit `lang` to infer it from file extensions. Matches print as `file:line: code` (1-based) — feed the locations to str_replace_editor for targeted edits.",
			"Set `rewrite` to preview a structural replacement (prints a diff, changes nothing); add `apply: true` to write the changes to files.",
			"No matches exit with code 1 and render as `(no matches)` — a normal result, not an error.",
			"Prefer this over grep when the target is a code structure (calls, definitions, imports, JSX); use grep for plain text and comments.",
		].join(" "),
		parameters: {
			pattern: {
				type: "string",
				required: true,
				description: "AST pattern to match. `$NAME` = one AST node, `$$$NAME` = a node sequence; literal code matches literally."
			},
			lang: {
				type: "string",
				description: "ast-grep language id (ts, tsx, js, jsx, py, go, rs, java, c, cpp, html, css, json, yaml, ...). Inferred from file extensions when omitted; set it when paths mix languages or the pattern is language-specific."
			},
			paths: {
				type: "string",
				description: "File or directory to search. Defaults to '.' (the session workspace); search a common parent directory instead of repeating calls."
			},
			globs: {
				type: "string",
				description: "Optional include/exclude glob, e.g. '*.ts' or '!*.test.ts'. One value per call."
			},
			context: {
				type: "number",
				description: "Lines of context to show around each match (search mode only, 0-10, default 0)."
			},
			rewrite: {
				type: "string",
				description: "Replacement pattern (may reuse `$NAME` captures). Presence switches to rewrite mode: without apply the tool prints a diff and changes nothing."
			},
			apply: {
				type: "boolean",
				description: "With rewrite: write the changes to files (ast-grep -U). Default false = preview diff only."
			},
			timeoutMs: {
				type: "number",
				description: "Timeout in milliseconds; the search is killed on expiry."
			},
			workdir: {
				type: "string",
				description: "Working directory for this call. Defaults to the session workspace; a relative path is resolved against it."
			}
		},
		output: {
			schema: {
				type: "object",
				additionalProperties: false,
				properties: {
					kind: { type: "string", required: true, const: "run" },
					exitCode: { required: true, oneOf: [{ type: "integer" }, { type: "null" }] },
					signal: { required: true, oneOf: [{ type: "string" }, { type: "null" }] },
					timedOut: { type: "boolean", required: true },
					timeoutMs: { type: "number", required: true },
					stdout: {
						type: "object",
						additionalProperties: false,
						required: true,
						properties: {
							text: { type: "string", required: true },
							truncated: { type: "boolean", required: true },
							spillPath: { type: "string" }
						}
					},
					stderr: {
						type: "object",
						additionalProperties: false,
						required: true,
						properties: {
							text: { type: "string", required: true },
							truncated: { type: "boolean", required: true },
							spillPath: { type: "string" }
						}
					},
					sandbox: {
						type: "object",
						additionalProperties: false,
						properties: {
							mode: { type: "string", required: true },
							denied: { type: "boolean", required: true },
							runnerFailed: { type: "boolean" }
						}
					}
				}
			},
			render: (args, value) => [{ type: "text", text: renderResult(args, value, maxOutputChars) }]
		},
		async execute(args, exec) {
			if (typeof args.pattern !== "string" || args.pattern.trim().length === 0) throw new Error("invalid pattern: expected a non-empty string");
			if (args.rewrite !== void 0 && String(args.rewrite).length === 0) throw new Error("invalid rewrite: expected a non-empty string when present");
			if (args.apply === true && args.rewrite === void 0) throw new Error("invalid apply: rewrite is required when apply is true");
			if (args.lang !== void 0 && !/^[a-z0-9][a-z0-9+-]*$/i.test(args.lang)) throw new Error(`invalid lang: expected an ast-grep language id, got ${JSON.stringify(args.lang)}`);
			if (args.context !== void 0 && (!Number.isInteger(args.context) || args.context < 0 || args.context > 10)) throw new Error("invalid context: expected an integer between 0 and 10");
			if (args.globs !== void 0 && (typeof args.globs !== "string" || args.globs.trim().length === 0)) throw new Error("invalid globs: expected a non-empty string");
			if (args.paths !== void 0 && (typeof args.paths !== "string" || args.paths.trim().length === 0)) throw new Error("invalid paths: expected a non-empty string");
			const policy = resolveSandboxPolicy(exec);
			const workdir = resolveWorkdir(args.workdir, exec, policy?.workspaceRoot);
			const parts = [BIN, "run", "-p", shQuote(args.pattern)];
			if (args.rewrite !== void 0) parts.push("-r", shQuote(args.rewrite));
			if (args.lang !== void 0) parts.push("-l", shQuote(args.lang));
			if (args.context !== void 0 && args.context > 0 && args.rewrite === void 0) parts.push("-C", String(args.context));
			if (args.globs !== void 0) parts.push("--globs", shQuote(args.globs));
			if (args.rewrite !== void 0 && args.apply === true) parts.push("-U");
			parts.push(args.paths !== void 0 ? shQuote(args.paths) : ".");
			const result = await ctx.shell.run(ctx.shell.resolve({
				command: parts.join(" "),
				...workdir !== void 0 ? { workdir } : {},
				...args.timeoutMs !== void 0 ? { timeoutMs: args.timeoutMs } : {},
				dshEnv: ctx.shellEnv.collect(exec),
				...policy !== void 0 ? { sandboxPolicy: policy } : {},
				signal: exec.signal
			}));
			if (result.aborted) {
				const error = new HarnessError("tool call aborted", TOOL_ABORTED);
				error.name = "AbortError";
				throw error;
			}
			return {
				kind: "run",
				exitCode: result.exitCode,
				signal: result.signal,
				timedOut: result.timedOut,
				timeoutMs: result.timeoutMs,
				stdout: { text: result.stdout.text, truncated: result.stdout.truncated, ...result.stdout.spillPath !== void 0 ? { spillPath: result.stdout.spillPath } : {} },
				stderr: { text: result.stderr.text, truncated: result.stderr.truncated, ...result.stderr.spillPath !== void 0 ? { spillPath: result.stderr.spillPath } : {} },
				...result.sandbox !== void 0 ? { sandbox: {
					mode: result.sandbox.mode,
					denied: result.sandbox.denied,
					...result.sandbox.runnerFailed !== void 0 ? { runnerFailed: result.sandbox.runnerFailed } : {}
				} } : {}
			};
		},
		presentCall: (args) => ({
			card: "generic",
			title: args.pattern,
			kind: "execute",
			rawInput: args.rewrite !== void 0 ? `${args.pattern} => ${args.rewrite}${args.apply === true ? " (apply)" : " (preview)"}` : args.pattern,
			content: [{
				type: "text",
				text: `ast-grep ${args.rewrite !== void 0 ? "rewrite" : "search"}${args.lang !== void 0 ? ` · ${args.lang}` : ""}`
			}]
		}),
		presentResult: (_args, result) => {
			const block = result.content.length === 1 ? result.content[0] : void 0;
			const raw = block !== void 0 && block.type === "text" ? block.text : "";
			return {
				card: "generic",
				content: [{ type: "text", text: `\`\`\`console\n${raw.replace(/\n+$/, "")}\n\`\`\`` }]
			};
		}
	}));
}

export { Config, apply, inject, name };
