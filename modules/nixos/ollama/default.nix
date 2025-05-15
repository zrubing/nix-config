{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  system,
  ...
}:
let
  mysecrets = inputs.mysecrets;
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  cfg = config.${namespace}.ollama;
in
{

  options.${namespace}.ollama = with lib; {
    enable = mkEnableOption "Enable ollama";
  };

  config = lib.mkIf cfg.enable {

    services.ollama = {
      enable = true;
      package = pkgs.ollama-rocm;
      acceleration = "rocm";
    };
  };

}
