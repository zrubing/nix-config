{ config, lib, pkgs, namespace, ... }:
with lib;
with lib.${namespace};
let
  cfg = config.${namespace}.hypridle;

  # noctalia 锁屏命令
  lockCmd = "noctalia-shell ipc call lockScreen lock";
  # niri 关闭显示器命令
  powerOffMonitors = "${pkgs.niri}/bin/niri msg action power-off-monitors";
in
{
  options.${namespace}.hypridle = with types; {
    enable = mkBoolOpt false "Enable hypridle";

    # 电池模式下的超时设置
    battery = {
      lockTime = mkOpt types.int 300 "Seconds before lock on battery";
      dpmsTime = mkOpt types.int 180 "Seconds before dpms off on battery";
      suspendTime = mkOpt types.int 600 "Seconds before suspend on battery";
    };

    # 插电模式下的超时设置
    ac = {
      lockTime = mkOpt types.int 600 "Seconds before lock on AC";
      dpmsTime = mkOpt types.int 300 "Seconds before dpms off on AC";
      suspendTime = mkOpt types.int 0 "Seconds before suspend on AC (0 = disabled)";
    };
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      hypridle
    ];

    xdg.configFile."hypr/hypridle.conf".text = ''
      general {
          lock_cmd = ${lockCmd}
          before_sleep_cmd = ${lockCmd}
          after_sleep_cmd = ${powerOffMonitors}
          ignore_dbus_inhibit = false
      }

      # 插电模式 (AC)
      listener {
          # 检测是否插电，如果插电则设置较长的超时
          timeout = ${toString cfg.ac.dpmsTime}
          on-timeout = if grep -q "discharging" /sys/class/power_supply/BAT*/status 2>/dev/null; then exit; fi; ${powerOffMonitors}
      }

      listener {
          timeout = ${toString cfg.ac.lockTime}
          on-timeout = if grep -q "discharging" /sys/class/power_supply/BAT*/status 2>/dev/null; then exit; fi; ${lockCmd}
      }

      # 电池模式
      listener {
          timeout = ${toString cfg.battery.dpmsTime}
          on-timeout = if grep -q "discharging" /sys/class/power_supply/BAT*/status 2>/dev/null; then ${powerOffMonitors}; fi
      }

      listener {
          timeout = ${toString cfg.battery.lockTime}
          on-timeout = if grep -q "discharging" /sys/class/power_supply/BAT*/status 2>/dev/null; then ${lockCmd}; fi
      }

      # 挂起 (仅在电池模式)
      listener {
          timeout = ${toString cfg.battery.suspendTime}
          on-timeout = if grep -q "discharging" /sys/class/power_supply/BAT*/status 2>/dev/null; then systemctl suspend; fi
      }
    '';

    # systemd 服务
    systemd.user.services.hypridle = {
      Unit = {
        Description = "Hypridle idle daemon";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.hypridle}/bin/hypridle";
        Restart = "on-failure";
        RestartSec = "5";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
