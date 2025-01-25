{ config, lib, pkgs, namespace, inputs, ... }:
with lib;
let
  cfg = config.${namespace}.javalib;
  javalib-dir = "${config.xdg.dataHome}/javalib";

in {
  options.${namespace}.javalib = with lib; { enable = mkEnableOption "Enable javalib"; };

  config = mkIf cfg.enable {

    home.packages = with pkgs;[
      lombok
    ];

    home.file."${javalib-dir}/lombok.jar".source = "${pkgs.lombok}/share/java/lombok.jar";

  };
}
