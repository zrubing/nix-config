{ config, lib, namespace, pkgs, ... }:
let cfg = config.${namespace}.linux.desktop;
in {
  options.${namespace}.linux.desktop = with lib; {
    enable = mkEnableOption "Enable Linux desktop";

    displayServer = mkOption { type = types.enum [ "x11" "wayland" ]; };
  };

  config = lib.mkIf cfg.enable {
    # Desktop environment
    # services.polkit-gnome-authentication-agent-1.enable = true;
    services.dunst.enable = true;
    programs.rofi.enable = true;

    programs.mpv.enable = true;
    #programs.imv.enable = true;

    #services.mpris-proxy.enable = true;
    #services.blueman-applet.enable = lib.mkDefault true;
    #services.network-manager-applet.enable = true;

    #services.twkwk.enable = false;

    home.packages = (with pkgs; [
      firefox
      dissent
      thunderbird
      trackma-gtk
      mupdf
      gimp
      tremotesf
      gpodder
      pwvucontrol
      pulseaudio # pactl is still useful for some stuff
      playerctl
    ]) ++ [
      (pkgs.writeShellScriptBin "xdg-terminal-exec" ''
        exec ${lib.getExe (pkgs.${config.${namespace}.terminal})} -e "$@"
      '')
    ];

    services.udiskie = {
      enable = true;
      automount = false;
      tray = "always";
    };

    # Theming and stuff
    dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";

    gtk = {
      enable = true;
      gtk2.extraConfig = ''
        gtk-theme-name = "Adwaita:dark"
        gtk-application-prefer-dark-theme = "true"
      '';
      gtk3.extraConfig.gtk-application-prefer-dark-theme = true;
    };

    home.pointerCursor = {
      package = pkgs.fuchsia-cursor;
      name = "Fuchsia";
      size = 24;
      gtk.enable = true;
      x11.enable = true;
    };

    # Installed .desktop files are found in
    # /etc/profiles/per-user/<username>/share/applications/
    xdg.mimeApps = {
      enable = true;
      defaultApplications = let
        applications = {
          "nnn.desktop" = [ "inode/directory" ];
          "mupdf.desktop" = [ "application/pdf" ];
          "imv-dir.desktop" = [
            "image/bmp"
            "image/gif"
            "image/jpeg"
            "image/jpg"
            "image/pjpeg"
            "image/png"
            "image/tiff"
            "image/x-bmp"
            "image/x-pcx"
            "image/x-png"
            "image/x-portable-anymap"
            "image/x-portable-bitmap"
            "image/x-portable-graymap"
            "image/x-portable-pixmap"
            "image/x-tga"
            "image/x-xbitmap"
          ];
          "firefox.desktop" = [
            "x-scheme-handler/http"
            "x-scheme-handler/https"
            "x-scheme-handler/chrome"
            "text/html"
            "application/xhtml+xml"
            "application/x-extension-htm"
            "application/x-extension-html"
            "application/x-extension-shtml"
            "application/x-extension-xhtml"
            "application/x-extension-xht"
          ];
          "thunderbird.desktop" = [
            "x-scheme-handler/mailto"
            "x-scheme-handler/mid"
            "x-scheme-handler/webcal"
            "x-scheme-handler/webcals"
            "message/rfc822"
            "text/calendar"
            "application/x-extension-ics"
          ];
        };
      in lib.attrsets.concatMapAttrs
      (application: mimes: lib.attrsets.genAttrs mimes (_mime: [ application ]))
      applications;
    };

    systemd.user.targets.tray = {
      Unit = {
        Description = "Home Manager System Tray";
        Requires = [ "graphical-session-pre.target" ];
      };
    };
  };
}
