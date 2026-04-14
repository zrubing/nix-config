{
  config,
  lib,
  pkgs,
  inputs,
  system,
  namespace,
  ...
}:

let
  cfg = config.${namespace}.programs.wechat;
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = system;
    config.allowUnfree = true;
  };

  wechat-wrapper = pkgs.writeShellScriptBin "wechat-wrapper" ''
    export QT_QPA_PLATFORM=xcb
    export QT_AUTO_SCREEN_SCALE_FACTOR=1

    # 与当前系统全局 fcitx 环境保持一致，避免 WeChat 在 XWayland 下拿到不兼容的 IME 变量
    export QT_IM_MODULE=fcitx
    export GTK_IM_MODULE=fcitx
    export XMODIFIERS="@im=fcitx"

    exec ${pkgs-unstable.wechat}/bin/wechat "$@"
  '';
in
{
  options.${namespace}.programs.wechat.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable WeChat wrapper and desktop entry.";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      wechat-wrapper
    ];

    xdg.desktopEntries.wechat = {
      name = "微信";
      genericName = "WeChat";
      startupNotify = true;
      exec = "${wechat-wrapper}/bin/wechat-wrapper %U";
      icon = "com.tencent.wechat";
      type = "Application";
      terminal = false;
      categories = [
        "Network"
        "InstantMessaging"
      ];
    };
  };
}
