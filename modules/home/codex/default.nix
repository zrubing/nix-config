{
  config,
  lib,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.codex;
  username = config.snowfallorg.user.name;
in
{
  options.${namespace}.modules.codex = {
    enable = lib.mkEnableOption "Codex configuration";
  };

  config = lib.mkIf cfg.enable {
    home.file.".codex/models.json".source = ./models.json;

    # config.toml contains the relay bearer token; render it through sops so the
    # secret is substituted during activation instead of being stored in Nix.
    sops.templates."codex-config" = lib.mkIf config.${namespace}.sops.enable {
      path = "/home/${username}/.codex/config.toml";
      mode = "0600";
      content = ''
        model = "deepseek-flash"
        model_provider = "deepseek"
        preferred_auth_method = "apikey"
        forced_login_method = "api"
        model_reasoning_effort = "max"
        web_search = "disabled"
        model_catalog_json = "~/.codex/models.json"

        [model_providers.deepseek]
        name = "deepseek"
        base_url = "${config.sops.placeholder."deepseek-relay/base_url"}"
        wire_api = "responses"
        experimental_bearer_token = "${config.sops.placeholder."deepseek-relay/api_key"}"
      '';
    };
  };
}
