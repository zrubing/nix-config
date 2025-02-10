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
    enable = mkBoolOpt false "Whether or not to use niri as the desktop environment.";
  };

  config = mkIf cfg.enable {
    services.xserver.enable = true;
    # You may need to comment out "services.displayManager.gdm.enable = true;"
    # services.displayManager.sddm.enable = true;
    services.desktopManager.plasma6.enable = true;
    internal.greetd.enable = true;
    internal.system.xkb.enable = true;
    internal.fonts.enable = true;

    environment.systemPackages = [ pkgs.wl-clipboard ];

    i18n.inputMethod.fcitx5.plasma6Support = true;

    #https://fcitx-im.org/wiki/Using_Fcitx_5_on_Wayland#KDE_Plasma
    i18n.inputMethod.fcitx5.waylandFrontend = true;
  };
}
