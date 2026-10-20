{
  config,
  pkgs,
  inputs,
  namespace,
  lib,
  ...
}:
with lib;
with lib.${namespace};
let
  cfg = config.${namespace}.noctalia;

  # 版本跟 flake 输入的 noctalia-shell（nightly，cachix 有二进制）。
  # 不用 nixpkgs 的 pkgs.noctalia：那是另一个版本线，和下面的配置键对不上。
  noctaliaPkg = inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  options.${namespace}.noctalia = with types; {
    enable = mkBoolOpt false "Enable noctalia shell";
  };

  config = mkIf cfg.enable {
    # niri 配置（输出 / 工作区 / 窗口规则 / keybind）的唯一来源在
    # modules/home/niri；这个模块只负责 shell 进程和它自己的 bar 配置。
    #
    # 用 systemd 用户单元而不是 niri 的 spawn-at-startup：崩溃能被 Restart 拉回，
    # 也不会被会话里某个进程组的退出带走（手工后台启动就会被带走）。
    systemd.user.services.noctalia = {
      Unit = {
        Description = "Noctalia Wayland shell";
        BindsTo = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };

      Install.WantedBy = [ "graphical-session.target" ];

      Service = {
        ExecStart = lib.getExe noctaliaPkg;
        Restart = "on-failure";
        RestartSec = 2;
        StandardOutput = "journal";
        StandardError = "journal";
        Environment = [ "DISPLAY=:0" ];
      };
    };

    programs.noctalia = {
      enable = true;
      package = noctaliaPkg;

      # 单元由上面这个定义，不用模块自带的（它依赖 wayland.systemd.target）。
      systemd.enable = false;

      settings = {
        accessibility.ui_scale = 1.0;

        shell = {
          font_family = "sans-serif";
          time_format = "{:%H:%M}";
          # 剪贴板归 modules/home/clipboard（cliphist + fuzzel），
          # 不在这里再挂一套历史。
          clipboard_enabled = false;
        };

        theme = {
          mode = "dark";
          source = "builtin";
          builtin = "Noctalia";
        };

        # 壁纸归 modules/home/swaybg（systemd 用户服务），锁屏归
        # swaylock / hypridle；noctalia 两者都不接管，否则同一件事两个实现。
        wallpaper.enabled = false;
        lockscreen.enabled = false;

        bar.main = {
          position = "top";
          thickness = 34;
          background_opacity = 1.0;
          radius = 12;
          margin_ends = 180;
          margin_edge = 10;
          padding = 14;
          widget_spacing = 6;
          scale = 1.0;
          capsule = false;
          shadow = true;

          start = [
            "launcher"
            "workspaces"
          ];
          center = [ "clock" ];
          end = [
            "network"
            "bluetooth"
            "volume"
            "battery"
            "notifications"
            "tray"
            "control-center"
          ];
        };

        # 通知守护：替掉 wayle 的。[notification] 没有"正文行数"选项——
        # toast 固定 3 行正文（源码 kToastMaxBodyLines），完整正文在通知中心
        # 的卡片里，点一下展开到底。
        notification = {
          enable_daemon = true;
          show_app_name = true;
          show_actions = true;
          layer = "top";
          scale = 1.0;
          offset_x = 20;
          offset_y = 8;
        };
      };
    };
  };
}
