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
    services.xwayland-satellite.enable = false;

    services.dunst.enable = true;
    services.swayidle.enable = true;

    ${namespace} = {
      copyq.enable = true;
      yazi.enable = true;
      rgbar.enable = true;
      xdg-portal.enable = true;
      linux.desktop = {
        enable = true;
        type = "niri";
      };

      # 使用niri-flake自带的xwayland-satellite
      niri-flake.enable = true;

    };
    home.packages = with pkgs; [
      mako
      xorg.xrdb
      papirus-icon-theme
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

    # set in xdg-config
    # home.file."${config.xdg.configHome}/xdg-desktop-portal/niri-portals.conf".source =
    #   ./niri-portals.conf;

    home.file."${config.xdg.dataHome}/custom-icons" = {
      source = ./icons;
      recursive = true;
    };

    home.file.".config/niri/config.kdl".source = ./config.kdl;
    home.file.".config/rgui/rgbar.toml".text = ''
      icon_path = "icon-config.toml"
      [icon]
      paths = [
          "${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark/64x64/devices",
          "${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark/64x64/apps",
          "${config.xdg.dataHome}/papirus-icon-theme"
      ]

    '';
    home.file.".config/rgui/icon-config.toml".text = ''
      paths = [
          "${config.xdg.dataHome}/papirus-icon-theme",
          "${config.xdg.dataHome}/custom-icons",
          "${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark/64x64/devices",
          "${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark/64x64/apps"
      ]

      [alias]
      app-launcher = [
            "org.codeberg.wangzh.rglauncher"
      ]
      emacs = [ "Emacs" ]
      brave = [ "Brave-browser" ]
      feishu = [ "Bytedance-feishu" ]
      dbeaver = [ "DBeaver" ]


    '';

  };
}
