{ pkgs, ... }:

let
  wechat-uos-wrapper = pkgs.writeShellScriptBin "wechat-uos-wrapper" ''
    export QT_QPA_PLATFORM=xcb
    export QT_AUTO_SCREEN_SCALE_FACTOR=1

    # 直接写死 fcitx5，避免依赖 XMODIFIERS, fuzzel启动时 XMODIFIERS 没有传进去
    export QT_IM_MODULE=fcitx5
    export GTK_IM_MODULE=fcitx5
    export XMODIFIERS="@im=fcitx5"

    exec ${pkgs.wechat-uos}/bin/wechat-uos "$@"
  '';
in
{
  home.packages = [
    wechat-uos-wrapper
  ];

  xdg.desktopEntries.wechat-uos = {
    name = "WeChat UOS";
    genericName = "WeChat";
    exec = "${wechat-uos-wrapper}/bin/wechat-uos-wrapper %U";
    icon = "wechat-uos";
    type = "Application";
    categories = [ "Network" "InstantMessaging" ];
  };
}
