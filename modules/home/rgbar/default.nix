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
  cfg = config.${namespace}.rgbar;
in
{
  options.${namespace}.rgbar = with types; {
    enable = mkBoolOpt false "Enable rgbar";
  };

  config = mkIf cfg.enable {
    systemd.user.services.rgbar = {
      Unit = {
        Description = "rgbar for niri Wayland";
        BindsTo = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        ExecStart = "${pkgs.${namespace}.rgbar}/bin/rgbar";
        StandardOutput = "journal";
      };
    };

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
      cherry-studio = [ "CherryStudio" ]


    '';

    # config with rgbar
    # 添加 xwayland-satellite 到系统包
    home.packages = with pkgs; [
      xwayland-satellite
    ];

    home.file.".config/niri/config.kdl".source = ./config.kdl;

    # set in xdg-config
    # home.file."${config.xdg.configHome}/xdg-desktop-portal/niri-portals.conf".source =
    #   ./niri-portals.conf;

    home.file."${config.xdg.dataHome}/custom-icons" = {
      source = ./icons;
      recursive = true;
    };

  };
}
