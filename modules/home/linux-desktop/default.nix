{
  config,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.linux.desktop;
in
{
  options.${namespace}.linux.desktop = with lib; {
    enable = mkEnableOption "Enable Linux desktop";

    type = mkOption {
      type = types.enum [
        "kde"
        "niri"
      ];
    };

  };

  config = lib.mkIf (cfg.enable && cfg.type == "niri") {
    services.dunst.enable = true;
    programs.mpv.enable = true;
    xdg = {
      enable = true;

      cacheHome = "${config.home.homeDirectory}/.cache";
      configHome = "${config.home.homeDirectory}/.config";
      dataHome = "${config.home.homeDirectory}/.local/share";
      stateHome = "${config.home.homeDirectory}/.local/state";

      # Installed .desktop files are found in
      # /etc/profiles/per-user/<username>/share/applications/
      mimeApps = {
        enable = true;
        defaultApplications = {
          "inode/directory" = [
            "nnn.desktop"
            "yazi.desktop"
          ];
          "application/pdf" = [ "sioyek.desktop" ];
          "image/bmp" = [ "imv-dir.desktop" ];
          "image/gif" = [ "imv-dir.desktop" ];
          "image/jpeg" = [ "imv-dir.desktop" ];
          "image/jpg" = [ "imv-dir.desktop" ];
          "image/pjpeg" = [ "imv-dir.desktop" ];
          "image/png" = [ "imv-dir.desktop" ];
          "image/tiff" = [ "imv-dir.desktop" ];
          "image/x-bmp" = [ "imv-dir.desktop" ];
          "image/x-pcx" = [ "imv-dir.desktop" ];
          "image/x-png" = [ "imv-dir.desktop" ];
          "image/x-portable-anymap" = [ "imv-dir.desktop" ];
          "image/x-portable-bitmap" = [ "imv-dir.desktop" ];
          "image/x-portable-graymap" = [ "imv-dir.desktop" ];
          "image/x-portable-pixmap" = [ "imv-dir.desktop" ];
          "image/x-tga" = [ "imv-dir.desktop" ];
          "image/x-xbitmap" = [ "imv-dir.desktop" ];

          "x-scheme-handler/http" = [ "firefox.desktop" ];
          "x-scheme-handler/https" = [ "firefox.desktop" ];
          "x-scheme-handler/chrome" = [ "firefox.desktop" ];
          "text/html" = [ "firefox.desktop" ];
          "application/xhtml+xml" = [ "firefox.desktop" ];
          "application/x-extension-htm" = [ "firefox.desktop" ];
          "application/x-extension-html" = [ "firefox.desktop" ];
          "application/x-extension-shtml" = [ "firefox.desktop" ];
          "application/x-extension-xhtml" = [ "firefox.desktop" ];
          "application/x-extension-xht" = [ "firefox.desktop" ];

          "x-scheme-handler/mailto" = [ "thunderbird.desktop" ];
          "x-scheme-handler/mid" = [ "thunderbird.desktop" ];
          "x-scheme-handler/webcal" = [ "thunderbird.desktop" ];
          "x-scheme-handler/webcals" = [ "thunderbird.desktop" ];
          "message/rfc822" = [ "thunderbird.desktop" ];
          "text/calendar" = [ "thunderbird.desktop" ];
          "application/x-extension-ics" = [ "thunderbird.desktop" ];
        };
      };
      desktopEntries = {

        brave = {
          name = "brave";
          exec = ''${pkgs.brave}/bin/brave'';
          icon = "brave-browser";
          terminal = false;
          type = "Application";
          categories = [
            "WebBrowser"
            "Network"
          ];
          mimeType = [
            "application/pdf"
            "application/rdf+xml"
            "application/rss+xml"
            "application/xhtml+xml"
            "application/xhtml_xml"
            "application/xml"
            "image/gif"
            "image/jpeg"
            "image/png"
            "image/webp"
            "text/html"
            "text/xml"
            "x-scheme-handler/http"
            "x-scheme-handler/https"
          ];
        };
      };
    };

    systemd.user.targets.tray = {
      Unit = {
        Description = "Home Manager System Tray";
        Requires = [ "graphical-session-pre.target" ];
      };
    };
  };
}
