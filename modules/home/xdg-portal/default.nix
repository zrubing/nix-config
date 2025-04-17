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

    xdg.portal = {
      enable = true;
      xdgOpenUsePortal = true;
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

    home.file."${config.xdg.configHome}/xdg-desktop-portal/portals.conf".text = ''
      ### $XDG_CONFIG_HOME/xdg-desktop-portal/portals.conf ###

      [preferred]
      org.freedesktop.impl.portal.FileChooser=termfilechooser
    '';

    #https://github.com/hunkyburrito/xdg-desktop-portal-termfilechooser?tab=readme-ov-file#installation
    xdg.configFile."xdg-desktop-portal-termfilechooser/config".text = ''
      ### $XDG_CONFIG_HOME/xdg-desktop-portal-termfilechooser/config ###

      [filechooser]
      cmd=${pkgs-unstable.xdg-desktop-portal-termfilechooser}/share/xdg-desktop-portal-termfilechooser/yazi-wrapper.sh
      default_dir=$HOME
      env=TERMCMD=${pkgs.foot}/bin/foot -T "terminal-filechooser"
    '';

  };
}
