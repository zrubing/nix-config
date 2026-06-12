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

    sops.secrets."anysearch/api_key" = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    sops.templates."anysearch-env" = {
      path = "/home/${username}/.pi/agent/skills/anysearch/.env";
      content = ''
        export ANYSEARCH_API_KEY="${config.sops.placeholder."anysearch/api_key"}"
      '';
    };

    sops.templates."trading-env" = {
      path = "/home/${username}/.config/trading/.env";
      content = ''
        export ANTHROPIC_API_KEY="${config.sops.placeholder."anthropic/api_key"}"
        export ANTHROPIC_BASE_URL="${config.sops.placeholder."anthropic/base_url"}"
        # Override provider via env: export TRADINGAGENTS_LLM_PROVIDER=anthropic
        # Add more keys below as needed:
        # export OPENAI_API_KEY="..."
        # export GOOGLE_API_KEY="..."
      '';
    };
  };
}
