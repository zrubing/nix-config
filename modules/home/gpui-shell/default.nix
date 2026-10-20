{
  config,
  pkgs,
  inputs,
  namespace,
  lib,
  system,
  ...
}:
with lib;
with lib.${namespace};
let
  cfg = config.${namespace}.gpui-shell;
  gpuishell = inputs.gpui-shell.packages.${system}.default;
in
{
  options.${namespace}.gpui-shell = with types; {
    enable = mkBoolOpt false "Enable GPUi Shell";
  };

  config = mkIf cfg.enable {
    # niri 配置（输出 / 工作区 / 窗口规则 / keybind）的唯一来源在
    # modules/home/niri；这个模块只负责 shell 进程和它自己的 bar 配置。
    home.packages = with pkgs; [
      gpuishell
    ];

    systemd.user.services.gpuishell = {
      Unit = {
        Description = "GPUi Shell for niri Wayland";
        BindsTo = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };

      Install.WantedBy = [ "graphical-session.target" ];

      Service = {
        ExecStart = lib.getExe gpuishell;
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

    xdg.configFile."gpuishell/config.toml" = {
      force = true;
      text = ''
        [bar]
        size = 32.0
        position = "right"
        start = ["LauncherBtn", "Workspaces", "SysInfo"]
        center = ["ActiveWindow"]
        end = ["Clock", "Mpris", "Notifications", "Systray", "KeyboardLayout", "Settings"]

        [bar.modules.clock]
        format_horizontal = "%H:%M"
        format_vertical = "%H\n%M"

        [launcher]
        width = 600.0
        height = 450.0
        margin_top = 100.0
        margin_right = 0.0
        margin_bottom = 0.0
        margin_left = 0.0

        [osd]
        position = "right"

        [control_center]
        position = "right"

        [control_center.power_actions]
        sleep = "systemctl suspend"
        reboot = "systemctl reboot"
        poweroff = "systemctl poweroff"
      '';
    };

  };
}
