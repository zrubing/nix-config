{
  config,
  lib,
  pkgs,
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
    home.packages = with pkgs; [
      xwayland-satellite
    ];

    home.activation.setupX = hm.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.xorg.xrdb}/bin/xrdb -merge ~/.Xresources
    '';

    home.file.".xinitrc".text = ''
      #!/usr/bin/env bash
      ${pkgs.xorg.xrdb}/bin/xrdb -merge ~/.Xresources
    '';

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
