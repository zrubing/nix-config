{ config, lib, pkgs, inputs , system, namespace, ... }:
let
  pkgs-unstable =  inputs.nixpkgs-unstable.legacyPackages.${system};

  cfg = config.${namespace}.modules.packages;
in {

  options.${namespace}.modules.packages = {
    enable = lib.mkEnableOption "packages";
  };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      localsend
    ];
  };

}
