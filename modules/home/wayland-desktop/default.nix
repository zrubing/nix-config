{ config, lib, namespace, pkgs, ... }:
let cfg = config.${namespace}.linux.desktop;
in lib.mkIf (cfg.enable && cfg.displayServer == "wayland") {
  #programs.rofi.package = pkgs.rofi-wayland;
  programs.fuzzel.enable = true;
  services.swaybg.enable = true;
  services.xwayland-satellite.enable = true;
  programs.swaylock.enable = true;
  programs.swaylock.package = pkgs.swaylock-effects;
  services.swayidle.enable = true;
  programs.waybar.enable = true;

  home.packages = with pkgs; [ wl-clipboard wev ];

  systemd.user.services.waybar.Unit = {
    # waybar should be started after graphical-session.target
    # instead of graphical-session-pre.target.
    After = lib.mkOverride 0 [ "graphical-session.target" ];

    # Provides tray.target
    BindsTo = [ "tray.target" ];
    Before = [ "tray.target" ];
  };

  systemd.user.services.udiskie.Unit = {
    After = lib.mkOverride 0 [ "graphical-session.target" "tray.target" ];
    PartOf = lib.mkOverride 0 [ "tray.target" ];
  };

  systemd.user.services.network-manager-applet.Unit = {
    After = lib.mkOverride 0 [ "graphical-session.target" "tray.target" ];
    PartOf = lib.mkOverride 0 [ "tray.target" ];
  };

  systemd.user.services.swayidle.Unit = {
    After = [ "graphical-session.target" ];
  };
}
