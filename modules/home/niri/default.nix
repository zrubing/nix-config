{
  config,
  lib,
  pkgs,
  namespace,
  inputs,
  ...
}:
with lib;
with lib.${namespace};
let
  hm = config.lib;
  cfg = config.${namespace}.desktop.niri;
in
{
  options.${namespace}.desktop.niri = with types; {
    enable = mkBoolOpt false "Enable niri config";
  };

  config = mkIf cfg.enable {
    services.xwayland-satellite.enable = true;
    services.dunst.enable = true;
    services.swayidle.enable = true;


    ${namespace} = {
      copyq.enable = true;
      yazi.enable = true;
      rgbar.enable = true;
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

    # 修复brave icon没有正确识别问题
    home.activation.setupIcons = hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -f "${config.xdg.dataHome}/papirus-icon-theme/Brave-browser.svg" ]; then
        mkdir -p ${config.xdg.dataHome}/papirus-icon-theme/
        cp ${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark/64x64/apps/brave.svg \
         ${config.xdg.dataHome}/papirus-icon-theme/Brave-browser.svg
      fi

    '';

    # set in xdg-config
    # home.file."${config.xdg.configHome}/xdg-desktop-portal/niri-portals.conf".source =
    #   ./niri-portals.conf;

    home.file.".config/niri/config.kdl".source = ./config.kdl;
    home.file.".config/rglauncher/rgbar.json".text = ''
      {
        "paths": [
          "${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark/64x64/devices",
          "${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark/64x64/apps",
          "${config.xdg.dataHome}/papirus-icon-theme"
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
