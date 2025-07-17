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
        defaultApplications =
          let
            applications = {
              "nnn.desktop" = [ "inode/directory" ];
              "sioyek.desktop" = [ "application/pdf" ];
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
              "brave.desktop" = [
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
              "yazi.desktop" = [
                "inode/directory"
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
          in
          lib.attrsets.concatMapAttrs (
            application: mimes: lib.attrsets.genAttrs mimes (_mime: [ application ])
          ) applications;
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
