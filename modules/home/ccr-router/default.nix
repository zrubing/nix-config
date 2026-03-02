{ config, lib, pkgs, inputs, system, namespace, ... }:

let
  pkgs-nix-ai = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
  cfg = config.internal.ccr-router;
in
{
  options.internal.ccr-router.enable = lib.mkEnableOption "ccr-router";

  config = lib.mkIf cfg.enable {
    systemd.user.services.ccr-router = {
      Unit = {
        Description = "CCR Router Service";
        After = [ "network.target" ];
      };

      Service = {
        ExecStart = "${pkgs-nix-ai.claude-code-router}/bin/ccr start";
        Restart = "on-failure";
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
