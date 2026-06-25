{
  config,
  lib,
  pkgs,
  namespace,
  inputs,
  ...
}:
with lib;
let
  cfg = config.${namespace}.sops;
  mysecrets = inputs.mysecrets;
  username = config.snowfallorg.user.name;
in
{
  options.${namespace}.sops = with lib; {
    enable = mkEnableOption "Enable sops configuration";
  };

  config = mkIf cfg.enable {
    sops.age.sshKeyPaths = [ "/home/${username}/.ssh/id_ed25519" ];

    sops.secrets."anthropic/base_url" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."anthropic/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."volc-coding/base_url" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."volc-coding/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."volc-coding/model" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."minimax-coding/base_url" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."minimax-coding/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."minimax-coding/model" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."qwen/base_url" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."qwen/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };


    sops.secrets."woodpecker/token" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."woodpecker/server" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."zot/username" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };
    sops.secrets."zot/password" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."deepseek/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."alphavantage/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."anysearch/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.secrets."opencode/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.templates."anysearch-env" = {
      path = "/home/${username}/.pi/agent/skills/anysearch/.env";
      content = ''
        export ANYSEARCH_API_KEY="${config.sops.placeholder."anysearch/api_key"}"
      '';
    };

    sops.templates."tradingagents.env" = {
      path = "/home/${username}/.config/tradingagents/.env";
      content = ''
        # --- LLM Provider ---
        export TRADINGAGENTS_LLM_PROVIDER=deepseek

        # --- DeepSeek (sops-managed) ---
        export DEEPSEEK_API_KEY="${config.sops.placeholder."deepseek/api_key"}"

        # --- Anthropic-compatible (Zhipu via sops) ---
        export ANTHROPIC_API_KEY="${config.sops.placeholder."anthropic/api_key"}"
        export ANTHROPIC_BASE_URL="${config.sops.placeholder."anthropic/base_url"}"

        # --- Alpha Vantage (sops-managed) ---
        export ALPHA_VANTAGE_API_KEY="${config.sops.placeholder."alphavantage/api_key"}"

        # --- Optional overrides ---
        # export TRADINGAGENTS_DEEP_THINK_LLM=deepseek-chat
        # export TRADINGAGENTS_QUICK_THINK_LLM=deepseek-chat
        # export TRADINGAGENTS_OUTPUT_LANGUAGE=Chinese
      '';
    };

    sops.templates."default-env" = {
      path = "/home/${username}/.config/default.env";
      content = ''
        export OPENCODE_API_KEY="${config.sops.placeholder."opencode/api_key"}"
        export DEEPSEEK_API_KEY="${config.sops.placeholder."deepseek/api_key"}"
        export ZAI_CODING_CN_API_KEY="${config.sops.placeholder."anthropic/api_key"}"
      '';
    };
  };
}
