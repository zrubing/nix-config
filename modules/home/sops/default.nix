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
  };
}
