{ config, lib, pkgs, namespace, inputs, ... }:
with lib;
let
  cfg = config.${namespace}.copyq;

in {
  options.${namespace}.copyq = with lib; { enable = mkEnableOption "Enable copyq"; };

  config = mkIf cfg.enable {

    services.copyq = {
      enable = true;
    };
  };
}
