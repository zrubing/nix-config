{
  lib,
  config,
  namespace,
  ...
}:

let
  shellCfg = config.${namespace}.shell;

  providers = {
    GLM = {
      baseUrlSecret = "anthropic/base_url";
      apiKeySecret = "anthropic/api_key";
      authEnvName = "ANTHROPIC_API_KEY";
      model = "GLM-4.7";
    };

    MiniMax = {
      baseUrlSecret = "minimax-coding/base_url";
      apiKeySecret = "minimax-coding/api_key";
      authEnvName = "ANTHROPIC_API_KEY";
      model = "MiniMax-M2.1";
    };

    Qwen = {
      baseUrlSecret = "qwen/base_url";
      apiKeySecret = "qwen/api_key";
      authEnvName = "ANTHROPIC_AUTH_TOKEN";
      model = "qwen3-max-2026-01-23";
    };

    Volc = {
      baseUrlSecret = "volc-coding/base_url";
      apiKeySecret = "volc-coding/api_key";
      authEnvName = "ANTHROPIC_API_KEY";
      modelSecret = "volc-coding/model";
    };
  };

  provider = providers.${shellCfg.provider};
  hasStaticModel = provider ? model;
  hasModelSecret = provider ? modelSecret;
in
{
  options.${namespace}.shell = with lib; {
    enable = mkOption {
      type = types.enum [ "bash" "fish" ];
      default = "bash";
      description = "Default shell to use";
    };
    provider = lib.mkOption {
      type = lib.types.enum [ "GLM" "MiniMax" "Qwen" "Volc" ];
      default = "GLM";
      description = "AI provider to use (GLM, MiniMax, Qwen, or Volc)";
    };
  };

  config = {
    home.sessionVariables = {
      API_TIMEOUT_MS = "3000000";
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    } // lib.optionalAttrs hasStaticModel {
      ANTHROPIC_MODEL = provider.model;
    };

    sops.templates."ai-provider.env".content = ''
      ANTHROPIC_BASE_URL=${config.sops.placeholder.${provider.baseUrlSecret}}
      ${provider.authEnvName}=${config.sops.placeholder.${provider.apiKeySecret}}
      ${lib.optionalString hasModelSecret "ANTHROPIC_MODEL=${config.sops.placeholder.${provider.modelSecret}}"}
    '';

    sops.templates."ai-provider.fish".content = ''
      set -gx ANTHROPIC_BASE_URL ${config.sops.placeholder.${provider.baseUrlSecret}}
      set -gx ${provider.authEnvName} ${config.sops.placeholder.${provider.apiKeySecret}}
      ${lib.optionalString hasModelSecret "set -gx ANTHROPIC_MODEL ${config.sops.placeholder.${provider.modelSecret}}"}
    '';
  };
}
