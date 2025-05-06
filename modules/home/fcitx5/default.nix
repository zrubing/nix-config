{
  lib,
  config,
  pkgs,
  namespace,
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

    home.sessionVariables =
      {
        GLFW_IM_MODULE = "ibus"; # IME support in kitty
        XMODIFIERS = "@im=fcitx";
        GTK_IM_MODULE = lib.mkForce "";
        QT_IM_MODULE = lib.mkForce "";

      }
      // lib.optionalAttrs
        (config.${namespace}.desktop.kde.enable || config.${namespace}.desktop.niri.enable)
        {
          GTK_IM_MODULE = lib.mkForce "fcitx5";
          QT_IM_MODULE = lib.mkForce "wayland";
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
