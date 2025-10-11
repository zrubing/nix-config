{
  pkgs,
  inputs,
  system,
  ...
}:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = system;
    config.allowUnfree = true;
  };

  wechat-uos-wrapper = pkgs.writeShellScriptBin "wechat-uos-wrapper" ''
    export QT_QPA_PLATFORM=xcb
    export QT_AUTO_SCREEN_SCALE_FACTOR=1

    # 直接写死 fcitx5，避免依赖 XMODIFIERS, fuzzel启动时 XMODIFIERS 没有传进去
    export QT_IM_MODULE=fcitx5
    export GTK_IM_MODULE=fcitx5
    export XMODIFIERS="@im=fcitx5"

    exec ${pkgs-unstable.wechat-uos}/bin/wechat-uos "$@"
  '';
in
{
  home.packages = [
    wechat-uos-wrapper
    #pkgs-unstable.wechat-uos
  ];

  xdg.desktopEntries.wechat-uos = {
    name = "微信";
    genericName = "WeChat";
    startupNotify = true;
    exec = "${wechat-uos-wrapper}/bin/wechat-uos-wrapper %U";
    icon = "com.tencent.wechat";
    type = "Application";
    terminal = false;
    categories = [
      "Network"
      "InstantMessaging"
    ];
  };
}
