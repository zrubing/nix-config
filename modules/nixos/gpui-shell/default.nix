{
  config,
  pkgs,
  inputs,
  lib,
  namespace,
  system,
  ...
}:
let
  cfg = config.${namespace}.gpui-shell;
in
{
  options.${namespace}.gpui-shell.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether to install gpuishell package on NixOS.";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      inputs.gpui-shell.packages.${system}.default
    ];
  };
}
