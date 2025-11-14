{
  config,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.linux.desktop;
  brave-wrapper = pkgs.writeScriptBin "brave" ''
    #!/bin/sh
    BRAVE_USER_FLAGS_FILE="$XDG_CONFIG_HOME/brave-flags.conf"
    if [[ -f $BRAVE_USER_FLAGS_FILE ]]; then
        USER_FLAGS="$(cat $BRAVE_USER_FLAGS_FILE | sed 's/#.*//')"
    else
        echo "not found conf file"
    fi
    ${pkgs.brave}/bin/brave $@ $USER_FLAGS
  '';
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

    home.packages = [
      brave-wrapper
    ];

    # 使用 home.file 管理 Brave 配置文件
    home.file.".config/brave-flags.conf".text = ''
      # Brave 浏览器启动参数配置
      # 用于启用远程调试，支持 niri-fuzzel-switcher 的标签页切换功能

      --remote-debugging-port=9222

      # 其他可选参数
      # --enable-features=UseOzonePlatform
      # --ozone-platform-hint=auto
      # --disable-features=VizDisplayCompositor
    '';

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
          exec = "${brave-wrapper}/bin/brave %U";
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
