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

  wechat-wrapper = pkgs.writeShellScriptBin "wechat-wrapper" ''
    export QT_QPA_PLATFORM=xcb

    # 不要在这里覆盖 QT_AUTO_SCREEN_SCALE_FACTOR。NixOS 侧已经统一设成 "0"
    # （modules/nixos/desktop/niri/xwayland-conf.nix：让 Xft.dpi 控制字号），
    # 而这个 wrapper 以前又把它设回 1，使微信成为全系统唯一走 Qt5 整数自动缩放
    # 的应用 —— 168/96 = 1.75 会被取整成 2，跟卫星实际使用的 1.75 对不上。
    # 注：这不是"窗口首次打开超高"的原因（那个是 xwayland-satellite 的 size
    # hints 单位错误，见 overlays/xwayland-satellite）；去掉这个变量后窗口
    # 请求值一个字节都没变。改这里只是消除与全局约定不一致的那处覆盖。

    # 与当前系统全局 fcitx 环境保持一致，避免 WeChat 在 XWayland 下拿到不兼容的 IME 变量
    export QT_IM_MODULE=fcitx
    export GTK_IM_MODULE=fcitx
    export XMODIFIERS="@im=fcitx"

    exec ${pkgs.unstable.wechat-uos}/bin/wechat-uos "$@"
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
