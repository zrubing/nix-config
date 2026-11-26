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

  # 微信的 FHS 启动器会向整个进程组 export 约 59 条 LD_LIBRARY_PATH（含它自带的
  # glibc 2.44）。微信用 QProcess 拉起的每个外部工具都继承这串路径，凡不是用它那份
  # glibc 编译的程序，动态链接阶段就直接失败：
  #   bash: symbol lookup error: .../glibc-2.44-57/lib/libc.so.6:
  #         undefined symbol: __pointer_chk_guard, version GLIBC_PRIVATE
  # 退出码 127，而微信丢弃子进程的 stdout/stderr，所以整条链路静默失败。
  #
  # 「在文件夹中显示」依赖其中三个工具，全部踩中：
  #   which dde-file-manager / nautilus / dbus-send → 全返回 127，
  #   微信据此认为没有 dbus-send，跳过 org.freedesktop.FileManager1.ShowItems
  #   （这条能定位到具体文件），退回 xdg-open，只打开所在目录。
  #
  # 垫片拿 FHS 自带的 /usr/bin/bash 当解释器：它和那串路径同源，能正常启动；
  # 先清掉 LD_LIBRARY_PATH，再 exec 真正的工具。
  host-tools-shim = pkgs.runCommand "wechat-host-tools-shim" { } ''
    install -d $out/bin

    cat > $out/bin/xdg-open <<'SHIM'
    #!/usr/bin/bash
    unset LD_LIBRARY_PATH
    exec ${pkgs.xdg-utils}/bin/xdg-open "$@"
    SHIM

    cat > $out/bin/which <<'SHIM'
    #!/usr/bin/bash
    unset LD_LIBRARY_PATH
    exec ${pkgs.which}/bin/which "$@"
    SHIM

    cat > $out/bin/dbus-send <<'SHIM'
    #!/usr/bin/bash
    unset LD_LIBRARY_PATH
    exec ${pkgs.dbus}/bin/dbus-send "$@"
    SHIM

    chmod +x $out/bin/*
  '';

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

    # FHS 环境里的 /etc/profile 只往 PATH 前面插目录，不清空，垫片目录会保留；
    # 而 FHS 的 /usr/bin 里没有 xdg-open/which/dbus-send，所以都会命中垫片。
    export PATH="${host-tools-shim}/bin:$PATH"

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
