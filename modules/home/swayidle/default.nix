{ config, lib, pkgs, namespace, ... }:
with lib;
with lib.${namespace};
let
  power-off-monitors = "${pkgs.niri}/bin/niri msg action power-off-monitors";
  swaylock = "${pkgs.swaylock-effects}/bin/swaylock";
  
  # 创建一个脚本来处理锁屏事件
  lockScript = pkgs.writeShellScript "lock-script" ''
    ${swaylock} -f
    ${power-off-monitors}
  '';

  # 创建一个脚本来处理睡眠前事件
  beforeSleepScript = pkgs.writeShellScript "before-sleep" ''
    ${pkgs.systemd}/bin/loginctl lock-session
  '';
in
{
  options.${namespace}.swayidle = with types; {
    enable = mkBoolOpt false "Enable swayidle";
    idleTime = mkOpt types.int 600 "Idle time before locking (in seconds)";
    sleepTime = mkOpt types.int 900 "Idle time before sleeping (in seconds)";
  };

  config = mkIf config.${namespace}.swayidle.enable {
    home.packages = with pkgs; [
      swayidle
      procps  # for pgrep
    ];

    services.swayidle = {
      enable = true;
      extraArgs = [ "-d" ];
      systemdTarget = "graphical-session.target";
      
      events = [
        {
          event = "before-sleep";
          command = beforeSleepScript.outPath;
        }
        {
          event = "lock";
          command = lockScript.outPath;
        }
      ];
      
      timeouts = [
        # 10分钟后关闭显示器
        {
          timeout = config.${namespace}.swayidle.idleTime;
          command = power-off-monitors;
        }
        # 15分钟后锁屏
        {
          timeout = config.${namespace}.swayidle.sleepTime;
          command = lockScript.outPath;
        }
        # 检查锁屏状态并关闭显示器
        {
          timeout = 10;
          command = "${pkgs.procps}/bin/pgrep -x swaylock && ${power-off-monitors}";
        }
      ];
    };

    # 确保 swayidle 在正确的会话中运行
    systemd.user.services.swayidle.Unit.After = [ "graphical-session.target" ];
    systemd.user.services.swayidle.Unit.PartOf = [ "graphical-session.target" ];
  };
}
