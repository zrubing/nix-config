{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.desktop.niri;
in
{
  config = lib.mkIf cfg.enable {

    environment.systemPackages = [ pkgs.xwayland-satellite ];

    systemd.packages = [ pkgs.xwayland-satellite ];
    systemd.user.services.xwayland-satellite.wantedBy = [ "niri.service" ];
  };
}
