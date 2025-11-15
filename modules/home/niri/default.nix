{
  config,
  lib,
  pkgs,
  namespace,
  inputs,
  ...
}:
with lib;
with lib.${namespace};
let
  hm = config.lib;
  cfg = config.${namespace}.desktop.niri;
in
{
  options.${namespace}.desktop.niri = with types; {
    enable = mkBoolOpt false "Enable niri config";
  };

  config = mkIf cfg.enable {
    # services.xwayland-satellite.enable = true;
    # services.dunst.enable = true;
    # services.swayidle.enable = true;

    ${namespace} = {
      #rgbar.enable = true;
      noctalia.enable = true;
      #copyq.enable = true;
      #yazi.enable = true;
      #xdg-portal.enable = true;
      linux.desktop = {
        enable = true;
        type = "niri";
      };

      # 使用niri-flake自带的xwayland-satellite
      niri-flake.enable = true;

    };
    home.packages = with pkgs; [
      swappy
      slurp

      mako
      xorg.xrdb
      papirus-icon-theme
    ];

  };
}
