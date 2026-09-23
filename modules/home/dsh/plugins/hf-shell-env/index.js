/**
 * dsh-hf-shell-env — inject the HuggingFace access token into every model
 * shell call through the trusted `DSH_*` namespace.
 *
 * Background: dsh's subprocess env builder (dsh-subprocess scrubbedParentEnv)
 * strips every host variable whose name matches /KEY|PASSWORD|SECRET|TOKEN/i
 * from agent bash/pwsh calls. HF_TOKEN matches (TOKEN), so even when the host
 * process holds it — dsh-web-start sources ~/.config/dsh.env, which sops
 * renders with HF_TOKEN (clan vars generator huggingface-token) — the agent's
 * shell never sees it. The official escape hatch is the shell-env registry
 * (@deepseek-ai/dsh-shell-env), the same trust channel OpenBao/Woodpecker use:
 * contributions land in the per-execution managed env AFTER the scrub, so
 * model-supplied values can never replace managed ones.
 *
 * Registry keys must live in the DSH_* namespace, so the injected name is
 * DSH_HF_TOKEN. hf CLI (huggingface_hub) and transformers/datasets read
 * HF_TOKEN from the environment, so the bridge is automatic instead of
 * documented: dsh.env sets BASH_ENV=/home/.../.dsh/dsh-bash-env.sh
 * (nix-managed) and every non-interactive `bash -c` the model runs sources
 * it, re-exporting the registered value under HF_TOKEN. Interactive
 * persistent shells are covered independently by ~/.bashrc (default.env).
 * No skill or prompt changes are needed; `hf download ...` works out of the
 * box.
 *
 * Registered in the host composition (cordis.patch.yml insert row + file:
 * dependency in the web profile), same dual-piece pattern as
 * dsh-openbao-shell-env / dsh-woodpecker-shell-env.
 */

/** Cordis plugin name used by loader diagnostics. */
const name = "hf-shell-env";

/** Wait for the shell-env registry service before registering. */
const inject = ["shellEnv"];

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {object} config - plugin config (unused)
 */
function apply(ctx, config) {
  ctx.shellEnv.register({
    name: "hf",
    variables: {
      DSH_HF_TOKEN: {
        description:
          "HuggingFace access token（HF_TOKEN 的受信副本；原名含 TOKEN 会被 dsh subprocess scrub，只能走 DSH_* 受信通道，经 BASH_ENV 桥接回 HF_TOKEN，hf CLI 与 transformers/datasets 直接可用）",
      },
    },
    resolve: () => {
      const token = process.env.HF_TOKEN;
      return token ? { DSH_HF_TOKEN: token } : {};
    },
  });
}

export { name, inject, apply };
