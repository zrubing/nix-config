{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
with lib;
with lib.${namespace};
let
  cfg = config.${namespace}.clipboard;

  cliphistBin = lib.getExe pkgs.cliphist;
  wlPasteBin = lib.getExe' pkgs.wl-clipboard "wl-paste";

  # 剪贴板 watcher / persist 都是会话级长驻进程：挂到 graphical-session.target，
  # 异常退出后自动重拉。三个 niri shell 模块里原来各抄了一份 watcher 和 Mod+V，
  # 统一收到这里，shell 模块只管自己的 bar/键位。
  sessionUnit = description: {
    Unit = {
      Description = description;
      BindsTo = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      Requisite = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  picker = pkgs.writeShellScriptBin "clipboard-picker" ''
    export PATH="${
      lib.makeBinPath [
        pkgs.cliphist
        pkgs.wl-clipboard
        pkgs.fuzzel
        pkgs.imagemagick
        pkgs.file
        pkgs.coreutils
      ]
    }:$PATH"
    export CLIPHIST_PREVIEW_HEIGHT="${toString cfg.previewHeight}"
    export CLIPHIST_PREVIEW_LINES="${toString cfg.lines}"
    ${builtins.readFile ./picker.sh}
  '';
in
{
  options.${namespace}.clipboard = with types; {
    enable = mkBoolOpt false "Enable clipboard history (cliphist + fuzzel image previews)";

    previewHeight = mkOption {
      type = ints.positive;
      default = 96;
      description = ''
        图片预览的行高（px）。fuzzel 的条目图标高度等于行高，
        所以这个值同时决定缩略图大小：96 约等于 90px 缩略图。
      '';
    };

    lines = mkOption {
      type = ints.positive;
      default = 6;
      description = "存在图片条目时一屏显示的行数。";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [
      picker
      pkgs.cliphist
      pkgs.wl-clipboard
      pkgs.${namespace}.cliphist-gui
    ];

    systemd.user.services = {
      cliphist-text = sessionUnit "Store text clipboard history" // {
        Service = {
          ExecStart = "${wlPasteBin} --type text --watch ${cliphistBin} store";
          Restart = "on-failure";
          RestartSec = 2;
        };
      };

      cliphist-image = sessionUnit "Store image clipboard history" // {
        Service = {
          ExecStart = "${wlPasteBin} --type image --watch ${cliphistBin} store";
          Restart = "on-failure";
          RestartSec = 2;
        };
      };

      # 微信等 X11 程序的 CLIPBOARD 要经 xwayland-satellite 桥接：卫星先向源程序要
      # TARGETS/数据，源程序慢或卡住时 Wayland 侧读取会整体失败（dsh-tui 每个后端只等
      # 3s，wl-paste/xclip/xsel 全超时就报 "no usable wl-paste / xclip / xsel"）。
      # persist 拿到内容后立刻换自己当 owner，慢读只在它自己进程里做，之后所有读取都走
      # 本地 Wayland source，不再依赖源程序。
      wl-clip-persist = sessionUnit "Persist Wayland clipboard contents" // {
        Service = {
          ExecStart = "${lib.getExe pkgs.wl-clip-persist} --clipboard regular";
          Restart = "on-failure";
          RestartSec = 2;
        };
      };
    };

    # wayle / noctalia / gpui-shell 共用，别再各写一份。
    # Mod+V：预览面板（GTK4 layer-shell，行内缩略图、Enter 复制、Del 删除）。
    programs.niri.settings.binds."Mod+V".action.spawn = [ "cliphist-gui" ];
    # Mod+Shift+V：保留原来的 fuzzel 纯键盘快速选择（文本流更快）。
    programs.niri.settings.binds."Mod+Shift+V".action.spawn = [ "clipboard-picker" ];
  };
}
