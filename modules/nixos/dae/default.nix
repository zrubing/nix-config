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
  cfg = config.${namespace}.dae;
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  mysecrets = inputs.mysecrets;
in
{
  options.${namespace}.dae = with lib; {
    enable = mkEnableOption "Enable dae";
  };

  config = lib.mkIf cfg.enable {

    age.secrets."dae-conf.dae".file = "${mysecrets}/dae-conf.dae.age";

    environment.systemPackages = with pkgs; [
      pkgs-unstable.dae
    ];

    services.dae = {
      enable = true;
      configFile = "/run/agenix/dae-conf.dae";
    };

  };
}
