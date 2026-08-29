/**
 * dsh-openbao-shell-env — inject the OpenBao LDAP agent password into every
 * model shell call through the trusted `DSH_*` namespace.
 *
 * Background: dsh's subprocess env builder (dsh-subprocess scrubbedParentEnv)
 * strips every host variable whose name matches /KEY|PASSWORD|SECRET|TOKEN/i
 * from agent bash/pwsh calls — deliberate credential hygiene. The official
 * escape hatch is the shell-env registry (@deepseek-ai/dsh-shell-env):
 * plugins register DSH_* keys with declared ownership; the registry rebuilds
 * the managed environment for EVERY shell execution and the executor injects
 * it after the scrub, so model-supplied values can never replace managed ones.
 *
 * This plugin mirrors the first-party example in dsh-web-app (register a
 * contributor with name + variables + resolve). The resolver reads the plain
 * value from the host process env, which dsh-web-start already sourced from
 * ~/.config/dsh.env (sops-rendered OPENBAO_LDAP_AGENT_PASSWORD). The agent
 * pairs it with OPENBAO_LDAP_AGENT_USERNAME (non-sensitive name, survives the
 * scrub) and BAO_ADDR to run `bao login -method=ldap` for dynamic MySQL
 * read-only credentials.
 *
 * Registered in the host composition (cordis.patch.yml insert row +
 * file: dependency in the web profile), same dual-piece pattern as
 * dsh-braces-sanitize.
 */

/** Cordis plugin name used by loader diagnostics. */
const name = "openbao-shell-env";

/** Wait for the shell-env registry service before registering. */
const inject = ["shellEnv"];

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {object} config - plugin config (unused)
 */
function apply(ctx, config) {
  ctx.shellEnv.register({
    name: "openbao",
    variables: {
      DSH_OPENBAO_LDAP_AGENT_PASSWORD: {
        description:
          "OpenBao LDAP agent 密码（LLDAP 用户密码），配合 OPENBAO_LDAP_AGENT_USERNAME 执行 bao login -method=ldap 领取动态 MySQL 只读凭证",
      },
    },
    resolve: () => {
      const value = process.env.OPENBAO_LDAP_AGENT_PASSWORD;
      return value ? { DSH_OPENBAO_LDAP_AGENT_PASSWORD: value } : {};
    },
  });
}

export { name, inject, apply };
