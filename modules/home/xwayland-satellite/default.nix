{
  config,
  lib,
  pkgs,
  inputs,
  system,
  ...
}:
let
  cfg = config.services.xwayland-satellite;
  hm = config.lib;
in
{
  options.services.xwayland-satellite = {
    enable = lib.mkEnableOption "Xwayland outside your Wayland";
  };

  config = lib.mkIf cfg.enable {

    # home.packages = with pkgs; [
    #   xwayland-satellite
    # ];

    # 暂时没用到，先生成一个文件
    home.file.".xinitrc".text = ''
      #!/usr/bin/env bash
      ${pkgs.xrdb}/bin/xrdb -merge ~/.Xresources
    '';

    systemd.user.services.xrdb = {
      Unit = {
        Description = "xrdb";
        PartOf = [ "graphical-session.target" ];
        After = [
          "graphical-session.target"
          "xwayland-satellite.service"
        ];
        Requisite = [ "xwayland-satellite.service" ];
      };

      Install = {
        WantedBy = [ "graphical-session.target" ];
      };

      Service = {
        Type = "oneshot";
        # 装载 home-manager 生成的那一份 ~/.Xresources（唯一来源，见
        # modules/home/xwayland-conf）。xrdb 默认动作就是 -load（整体替换），
        # 显式写出来是为了说明这里会清掉 Xwayland 自己设的 Xft.dpi —— 两者取值
        # 相同（都是 96 × 全局 scale），所以不冲突。
        ExecStart = "/usr/bin/env 'DISPLAY=:0' ${pkgs.xrdb}/bin/xrdb -load ${config.xresources.path}";
        Environment = "DISPLAY=:0";
      };
    };

    systemd.user.services."xwayland-satellite" = {
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
      Unit = {
        Description = "Xwayland outside your Wayland";
        BindsTo = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
        Before = [ "xrdb.service" ];
      };
      Service = {
        Type = "notify";
        NotifyAccess = "all";
        ExecStart = "${lib.getExe pkgs.xwayland-satellite} :0";
        StandardOutput = "journal";
        Restart = "on-failure";
        Environment = "RUST_BACKTRACE=1 RUST_LOG=trace";
      };
    };

  };
}
