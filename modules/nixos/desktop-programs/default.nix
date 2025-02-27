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
    ];

  };
}
