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
  cfg = config.${namespace}.desktop.niri;
in
{
  options.${namespace}.desktop.niri = with lib; {
    enable = mkEnableOption "Enable niri config";
  };

  config = mkIf cfg.enable {
    services.xwayland-satellite.enable = true;
    services.dunst.enable = true;

    home.packages = with pkgs; [papirus-icon-theme swaylock];
    home.file.".config/niri/config.kdl".source = ./config.kdl;
    home.file.".config/rglauncher/rgbar.json".text = ''
      {
        "paths": [
          "${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark/64x64/devices",
          "${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark/64x64/apps"
        ],
        "alias": {
          "app-launcher": [
            "org.codeberg.wangzh.rglauncher"
          ],
          "code": [
            "chrome-obcppbejhdfcplncjdlmagmpfjhmipii-Default"
          ]
        }
      }


    '';

  };
}
