{ lib,config, pkgs, namespace, ... }:

let cfg = config.${namespace}.modules.fcitx5;
in {

  options.${namespace}.modules.fcitx5 = {
    enable = lib.mkEnableOption "fcitx5";
  };

  config = lib.mkIf cfg.enable {

    xdg.configFile = {
      "fcitx5/profile" = {
        source = ./profile;
        # every time fcitx5 switch input method, it will modify ~/.config/fcitx5/profile,
        # so we need to force replace it in every rebuild to avoid file conflict.
        force = true;
      };
    };



    systemd.user.services.fcitx5-daemon.Unit = lib.mkForce {

      Description = "Fcitx5 input method editor";
      PartOf = [ "graphical-session.target" ];
      After = [ "niri.service" ];  # 确保在 niri.service 之后启动
      Requires = [ "niri.service" ];  # 确保 niri.service 已经启动

    };

    i18n.inputMethod = {
      enabled = "fcitx5";
      fcitx5.addons = with pkgs; [
        # for flypy chinese input method
        fcitx5-rime
        # needed enable rime using configtool after installed
        fcitx5-configtool
        fcitx5-chinese-addons
        # fcitx5-mozc    # japanese input method
        fcitx5-gtk # gtk im module
      ];
    };

  };
  #home.file.".config/rime/default.custom.yaml".source = ./rime-data-flypy/share/rime-data/default.custom.yaml;


}
