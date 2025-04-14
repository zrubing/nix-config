{
  config,
  lib,
  pkgs,
  namespace,
  inputs,
  system,
  ...
}@args:
with lib;
with lib.${namespace};
let
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  cfg = config.${namespace}.xdg-portal;
in
{
  options.${namespace}.xdg-portal = with types; {
    enable = mkBoolOpt false "Enable xdg-portal";
  };

  config = mkIf cfg.enable {

    # 默认的没带after，partof，启动会超时
    systemd.user.services.xdg-desktop-portal-gtk = {
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
    };

    xdg.portal = {
      enable = true;
      extraPortals = with pkgs; [
        xdg-desktop-portal-gtk
        xdg-desktop-portal-gnome
        gnome-keyring
        pkgs-unstable.xdg-desktop-portal-termfilechooser
      ];
      config = {
        niri = {
          default = "gnome;gtk";
          "org.freedesktop.impl.portal.Access" = "gtk";
          "org.freedesktop.impl.portal.Notification" = "gtk";
          "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
          "org.freedesktop.impl.portal.FileChooser" = "termfilechooser";
        };
      };

    };
  };
}
