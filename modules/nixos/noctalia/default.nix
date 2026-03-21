{
  config,
  pkgs,
  inputs,
  lib,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.noctalia;
in
{
  options.${namespace}.noctalia.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to install noctalia-shell package on NixOS.";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      inputs.noctalia.packages.${stdenv.hostPlatform.system}.default
    ];
  };
}
