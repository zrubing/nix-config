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
  cfg-xwayland = config.xwayland;
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
      ${pkgs.xorg.xrdb}/bin/xrdb -merge ~/.Xresources
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
        ExecStart = "/usr/bin/env 'DISPLAY=:0' ${pkgs.xorg.xrdb}/bin/xrdb ${cfg-xwayland.x-resources.source}";
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
        ExecStart = "${lib.getExe pkgs.xwayland-satellite-unstable} :0";
        StandardOutput = "journal";
        Restart = "on-failure";
        Environment = "RUST_BACKTRACE=1 RUST_LOG=debug";
      };
    };

  };
}
