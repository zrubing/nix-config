{
  config,
  lib,
  pkgs,
  namespace,
  ...
}@args:
with lib;
with lib.${namespace};
let
  cfg = config.${namespace}.desktop.niri;
  xwayland-conf = import ./xwayland-conf.nix args;
in
{
  options.${namespace}.desktop.niri = with types; {
    enable = mkBoolOpt false "Whether or not to use niri as the desktop environment.";
  };

  config = mkIf cfg.enable (mkMerge [
    xwayland-conf
    {

      services.power-profiles-daemon.enable = true;
      services.upower.enable = true;
      hardware.bluetooth.enable = true;

      services.flatpak.enable = true;
      environment.systemPackages = with pkgs; [
        dunst
        pkgs.${namespace}.rgbar
        fuzzel
        wl-clipboard

        pkgs.${namespace}.reqable
        brightnessctl
      ];
      programs.niri.enable = true;
      ${namespace} = {
        greetd.enable = true;
        fonts.enable = true;
      };
    }
  ]);
}
