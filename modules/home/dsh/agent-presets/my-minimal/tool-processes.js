// The `start_process` tool: the agent-facing half of aliou's pi-processes,
// ported to dsh's own seams. pi-processes targets pi's extension API
// (@earendil-works/pi-coding-agent) and its TUI panels, which dsh cannot
// load — dsh's only pi-related package, dsh-llm-pi-ai, is an LLM API adapter,
// not an extension host. This re-expresses the capability the agent actually
// got from it: spawn a long-running command without blocking the conversation.
// The process handle registers with the host `ctx.jobs` runtime, so ids,
// completion notices, `job_output` deltas and `job_kill` cancellation are
// generic, and the `@deepseek-ai/dsh-tool-jobs` row in this preset supplies
// those collection controls. The web UI's session-header jobs list
// (dsh-client-ui-jobs) shows running and finished processes — the dsh
// counterpart of pi-processes' process dock. The persistent PTY shell stays
// free for foreground work: background spawns here do not occupy it.
//
// The preset row loads this file through a relative specifier, so the module
// travels with the preset (dsh-agent-presets: relative names resolve against
// the preset directory). A preset directory has no node_modules ancestor that
// reaches the harness, so bare @deepseek-ai/* imports would fail; nix builds
// this source beside a node_modules symlink back to the installed harness's
// own dependency tree (modules/home/dsh: dsh-tool-processes).

import z from "@deepseek-ai/schemastery";
import { isAbsolute, resolve } from "node:path";
import { TOOL_ABORTED, defineTool } from "@deepseek-ai/dsh-tools";
import { HarnessError } from "@deepseek-ai/dsh-llm";
import { canonicalPath, sandboxDenialMarker } from "@deepseek-ai/dsh-sandbox";

const name = "tool-processes";
const inject = ["tools", "shell", "shellEnv"];

/** Runtime configuration schema; nothing to configure today. */
const Config = z.object({});

/** Map a settled process onto the generic task-outcome vocabulary (as dsh-tool-bash). */
function processOutcome(proc) {
  if (proc.status === "killed") return {
    status: "killed",
    detail: proc.signal !== null ? `signal: ${proc.signal}` : "killed before exit"
  };
  return { status: "completed", detail: `exit code: ${proc.exitCode ?? 0}` };
}

/** Shape one incremental read into the `job_output` delta, with loss/sandbox notices. */
function renderProcessRead(read, sandbox) {
  const notices = [];
  if (read.lossy) {
    const paths = [read.stdoutSpillPath, read.stderrSpillPath].filter((path) => path !== void 0);
    notices.push(`[some output was dropped from memory; full output: ${paths.length > 0 ? paths.join(", ") : "(unavailable)"}]`);
  }
  if (sandbox?.runnerFailed) notices.push(`[sandbox: the sandbox runner itself failed under ${sandbox.mode} mode — the command did not run; this is a sandbox problem, not a command failure]`);
  else if (sandbox?.denied) notices.push(sandboxDenialMarker(sandbox.mode));
  if (notices.length === 0) return read.delta;
  return `${read.delta}${read.delta.length > 0 && !read.delta.endsWith("\n") ? "\n" : ""}${notices.join("\n")}`;
}

/** Resolve an explicit workdir against the session cwd (as dsh-tool-bash's resolveWorkdir). */
function resolveWorkdir(modelWorkdir, exec, policyWorkspaceRoot) {
  const sessionCwd = policyWorkspaceRoot ?? (exec.agent?.session.header.cwd === void 0 ? void 0 : canonicalPath(exec.agent.session.header.cwd));
  if (modelWorkdir === void 0) return sessionCwd;
  if (sessionCwd !== void 0 && !isAbsolute(modelWorkdir)) return resolve(sessionCwd, modelWorkdir);
  return modelWorkdir;
}

function apply(ctx, config = {}) {
  const defaultMode = ctx.shell.sandboxMode;
  const sandboxPolicy = defaultMode === void 0 ? void 0 : ctx.get("sandboxPolicy");
  if (defaultMode !== void 0 && sandboxPolicy === void 0) throw new Error("tool-processes: the mounted shell executor confines but ctx.sandboxPolicy is missing");
  /** Resolve the complete standing policy for this call when a confining executor is mounted. */
  const resolveSandboxPolicy = (exec) => sandboxPolicy?.resolve(exec.agent === void 0 ? {} : { session: exec.agent.session });

  ctx.tools.register(defineTool({
    name: "start_process",
    description: "Start a long-running process in the background (dev servers, test watchers, builds, log tails) without blocking the conversation. The call returns a job id immediately; completion notices arrive in-session automatically — do not poll or sleep on a running process, keep working on independent steps. Read output with `job_output`, stop with `job_kill`, list with `job_list`. Each call is one fresh process: no state persists between calls — pass `workdir` instead of using `cd`. Prefer this over shell background patterns (`&`, `nohup`, `disown`) when the task needs structured output collection, completion notices, or later cancellation; use the persistent `bash` tool for foreground work.",
    parameters: {
      command: {
        type: "string",
        required: true,
        description: "The command to run in the background."
      },
      name: {
        type: "string",
        required: true,
        description: "Short friendly name for the process (e.g. 'dev-server', 'test-watcher'); shown in job listings and completion notices."
      },
      description: {
        type: "string",
        required: true,
        description: "Clear, concise description of what this process does in active voice, 5-10 words (shown in the UI)."
      },
      workdir: {
        type: "string",
        description: "Working directory for the process. Defaults to the session workspace; a relative path is resolved against it."
      }
    },
    output: {
      schema: {
        type: "object",
        additionalProperties: false,
        properties: {
          kind: { type: "string", required: true, const: "background" },
          jobId: { type: "string", required: true }
        }
      },
      render: (_args, value) => [{
        type: "text",
        text: `started background job ${value.jobId}`
      }]
    },
    async execute(args, exec) {
      if (args.command.trim().length === 0) throw new Error("invalid command: expected a non-empty string");
      const jobs = ctx.get("jobs");
      if (jobs === void 0) throw new Error("background jobs unavailable: the host composition must mount @deepseek-ai/dsh-jobs-local");
      if (exec.signal.aborted) {
        const error = new HarnessError("tool call aborted", TOOL_ABORTED);
        error.name = "AbortError";
        throw error;
      }
      const policy = resolveSandboxPolicy(exec);
      const workdir = resolveWorkdir(args.workdir, exec, policy?.workspaceRoot);
      const request = {
        command: args.command,
        ...workdir !== void 0 ? { workdir } : {},
        dshEnv: ctx.shellEnv.collect(exec),
        ...policy !== void 0 ? { sandboxPolicy: policy } : {}
      };
      return {
        kind: "background",
        jobId: jobs.start({
          kind: "process",
          label: `${args.name}: ${args.command}`,
          ...exec.agent ? { owner: exec.agent } : {},
          run: () => {
            const proc = ctx.shell.start(ctx.shell.resolve(request));
            return {
              cancel: () => void proc.kill(),
              done: proc.done.then(() => processOutcome(proc)),
              readOutput: () => renderProcessRead(proc.readOutput(), proc.sandbox)
            };
          }
        })
      };
    },
    presentCall: (args) => ({
      card: "generic",
      title: args.command,
      kind: "execute",
      rawInput: args.command,
      content: [{ type: "text", text: args.description }]
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
