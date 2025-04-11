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

    ${namespace} = {
      yazi.enable = true;
      linux.desktop = {
        enable = true;
        type = "niri";
      };
    };
    xdg.desktopEntries = {
      "brave" = {
        name = "brave";
        exec = "brave";
        type = "Application";
        categories = [ "WebBrowser" ];
      };
    };

    home.packages = with pkgs; [
      mako
      papirus-icon-theme
      swaylock
      (pkgs.writeScriptBin "brave" ''
        #!/bin/sh
        BRAVE_USER_FLAGS_FILE="$XDG_CONFIG_HOME/brave-flags.conf"
        if [[ -f $BRAVE_USER_FLAGS_FILE ]]; then
            USER_FLAGS="$(cat $BRAVE_USER_FLAGS_FILE | sed 's/#.*//')"
        else
            echo "not found conf file"
        fi
        ${pkgs.brave}/bin/brave $@ $USER_FLAGS
      '')

    ];

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
