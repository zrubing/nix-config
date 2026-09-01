/**
 * dsh-woodpecker-shell-env — inject the Woodpecker CI server address and
 * access token into every model shell call through the trusted `DSH_*` namespace.
 *
 * Background: dsh's subprocess env builder (dsh-subprocess scrubbedParentEnv)
 * strips every host variable whose name matches /KEY|PASSWORD|SECRET|TOKEN/i
 * from agent bash/pwsh calls. WOODPECKER_TOKEN matches (TOKEN), so even when
 * the host process holds it — dsh-web-start sources ~/.config/dsh.env, which
 * sops renders with WOODPECKER_SERVER/WOODPECKER_TOKEN for woodpecker-cli —
 * the agent's shell never sees it. The official escape hatch is the shell-env
 * registry (@deepseek-ai/dsh-shell-env), the same trust channel OpenBao uses:
 * contributions land in the per-execution managed env AFTER the scrub, so
 * model-supplied values can never replace managed ones.
 *
 * Registry keys must live in the DSH_* namespace, so the injected names are
 * DSH_WOODPECKER_SERVER / DSH_WOODPECKER_TOKEN. woodpecker-cli reads
 * WOODPECKER_SERVER/WOODPECKER_TOKEN from its own env (verified against
 * woodpecker-cli 3.16.0 with a dummy server: env values are honored before the
 * context/keyring fallback), so the bridge is automatic instead of documented:
 * dsh.env sets BASH_ENV=/home/.../.dsh/dsh-bash-env.sh (nix-managed) and every
 * non-interactive `bash -c` the model runs sources it, re-exporting the
 * registered values under the CLI's own names. Interactive persistent shells
 * are covered independently by ~/.bashrc (modules/home/bash). No skill or
 * prompt changes are needed; the plain `woodpecker-cli ...` command works.
 *
 * Registered in the host composition (cordis.patch.yml insert row + file:
 * dependency in the web profile), same dual-piece pattern as
 * dsh-openbao-shell-env.
 */

/** Cordis plugin name used by loader diagnostics. */
const name = "woodpecker-shell-env";

/** Wait for the shell-env registry service before registering. */
const inject = ["shellEnv"];

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {object} config - plugin config (unused)
 */
function apply(ctx, config) {
  ctx.shellEnv.register({
    name: "woodpecker",
    variables: {
      DSH_WOODPECKER_SERVER: {
        description:
          "Woodpecker CI 服务器地址（WOODPECKER_SERVER 的受信副本；BASH_ENV 桥接自动转回 WOODPECKER_SERVER，woodpecker-cli 直接可用）",
      },
      DSH_WOODPECKER_TOKEN: {
        description:
          "Woodpecker CI 访问令牌（WOODPECKER_TOKEN 的受信副本；原名含 TOKEN 会被 dsh subprocess scrub，只能走 DSH_* 受信通道，经 BASH_ENV 桥接回原名字）",
      },
    },
    resolve: () => {
      const server = process.env.WOODPECKER_SERVER;
      const token = process.env.WOODPECKER_TOKEN;
      const out = {};
      if (server) out.DSH_WOODPECKER_SERVER = server;
      if (token) out.DSH_WOODPECKER_TOKEN = token;
      return out;
    },
  });
}

export { name, inject, apply };
