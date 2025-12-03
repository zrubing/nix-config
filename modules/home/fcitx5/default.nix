{
  lib,
  config,
  pkgs,
  namespace,
  inputs,
  ...
}:

let
  cfg = config.${namespace}.modules.fcitx5;
in
{

  options.${namespace}.modules.fcitx5 = {
    enable = lib.mkEnableOption "fcitx5";
  };

  config = lib.mkIf cfg.enable {

    xdg = {
      dataFile = {
        "fcitx5/rime/amz-v2n3m1-zh-hans.gram" = {
          source = inputs.rime-3gram;
        };
        "fcitx5/rime/rime_ice.custom.yaml" = {
          text = ''
            patch:
              traditionalize/opencc_config: s2hk.json
              grammar:
                language: amz-v2n3m1-zh-hans
                collocation_max_length: 5
                collocation_min_length: 2
              translator/contextual_suggestions: true
              translator/max_homophones: 7
              translator/max_homographs: 7
          '';
        };
      };
    };

    home.sessionVariables = {
      GLFW_IM_MODULE = lib.mkForce "ibus"; # IME support in kitty and fuzzel
      XMODIFIERS = "@im=fcitx";
      GTK_IM_MODULE = lib.mkForce "";
      QT_IM_MODULE = lib.mkForce "";

    }
    //
      lib.optionalAttrs
        (config.${namespace}.desktop.kde.enable || config.${namespace}.desktop.niri.enable)
        {
          GTK_IM_MODULE = lib.mkForce "fcitx5";
          QT_IM_MODULE = lib.mkForce "fcitx";
        };

    i18n.inputMethod = {
      type = "fcitx5";
      enable = true;
      fcitx5.addons = with pkgs; [
        # for flypy chinese input method
        fcitx5-rime
        # needed enable rime using configtool after installed
        qt6Packages.fcitx5-chinese-addons
        qt6Packages.fcitx5-configtool
        # fcitx5-mozc    # japanese input method
        fcitx5-gtk # gtk im module
        qt6Packages.fcitx5-skk-qt
      ];
    };

    systemd.user.services = {
      "fcitx5" = {
        Install = {
          WantedBy = [ "graphical-session.target" ];
        };
        Unit = {
          PartOf = [ "graphical-session.target" ];
          After = [
            "graphical-session.target"
            "xwayland-satellite.service"
          ];
        };
        Service = {
          ExecStart = "${lib.getExe' config.i18n.inputMethod.package "fcitx5"} --replace";
          Restart = "on-failure";
        };
      };
    };

  };
  #home.file.".config/rime/default.custom.yaml".source = ./rime-data-flypy/share/rime-data/default.custom.yaml;

}
