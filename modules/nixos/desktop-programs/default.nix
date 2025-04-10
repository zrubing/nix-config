{
  config,
  lib,
  namespace,
  pkgs,
  inputs,
  system,
  ...
}:
let
  cfg = config.${namespace}.desktop-programs;
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  mysecrets = inputs.mysecrets;
in
{
  options.${namespace}.desktop-programs = with lib; {
    enable = mkEnableOption "Enable dae";
  };

  config = lib.mkIf cfg.enable {

    environment.systemPackages = with pkgs; [
      shotcut
      mpv

      # support 64-bit only
      (pkgs-unstable.wine.override { wineBuild = "wine64"; })
      pkgs-unstable.wineWowPackages.stagingFull
      pkgs-unstable.wineWowPackages.stable
      # winetricks (all versions)
      pkgs-unstable.winetricks
      # native wayland support (unstable)
      pkgs-unstable.wineWowPackages.waylandFull
    ];

  };
}
