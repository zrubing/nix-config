{
  config,
  pkgs,
  lib,
  namespace,
  ...
}:
with lib;
with lib.${namespace};
let
  cfg = config.${namespace}.wayle;
  wayleBin = lib.getExe pkgs.wayle;
in
{
  options.${namespace}.wayle = with types; {
    enable = mkBoolOpt false "Enable Wayle shell";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      pkgs.wayle
      pkgs.${namespace}.niri-fuzzel-switcher
    ];

    # niri 配置（工作区 / 窗口规则 / keybind）的唯一来源在 modules/home/niri；
    # 这个模块只负责 shell 进程本身和它自己的 bar 配置。
    systemd.user.services.wayle = {
      Unit = {
        Description = "Wayle Wayland Shell";
        BindsTo = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };

      Install.WantedBy = [ "graphical-session.target" ];

      Service = {
        ExecStart = "${wayleBin} shell";
        Restart = "on-failure";
        RestartSec = 2;
        StandardOutput = "journal";
        StandardError = "journal";
        Environment = [
          "DISPLAY=:0"
          "RUST_BACKTRACE=1"
        ];
      };
    };

    xdg.configFile."wayle/config.toml" = {
      force = true;
      text = ''
        [bar]
        location = "top"
        scale = 1.0

        [[bar.layout]]
        monitor = "*"
        left = ["dashboard"]
        center = ["niri-workspaces", "window-title"]
        right = ["volume", "network", "bluetooth", "battery", "clock", "notifications", "systray"]

        [modules.clock]
        format = "%H:%M"

        [osd]
        monitor = "*"
      '';
    };
  };
}
