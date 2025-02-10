{
  options,
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
with lib;
with lib.${namespace};
let
  cfg = config.${namespace}.desktop.kde;
in
{
  options.${namespace}.desktop.kde = with types; {
    enable = mkBoolOpt false "Whether or not to use kde as the desktop environment.";
  };

  config = mkIf cfg.enable {

    home.packages = with pkgs; [
      brave
    ];
  };
}
