{ config, lib, pkgs, ... }:
let cfg = config.services.xwayland-satellite;
in {
  options.services.xwayland-satellite = {
    enable = lib.mkEnableOption "Xwayland outside your Wayland";
  };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs;[
      xwayland-satellite
    ];


    systemd.user.services.xwayland-satellite = {
      Unit = {
        Description = "Xwayland outside your Wayland";
        BindsTo = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        Type = "notify";
        NotifyAccess = "all";
        ExecStart = "${pkgs.xwayland-satellite}/bin/xwayland-satellite";
        StandardOutput = "journal";
      };
    };
  };
}
