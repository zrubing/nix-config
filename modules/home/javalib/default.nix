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
    # home.file."${javalib-dir}/java-debug.jar".source = "${pkgs.${namespace}.java-debug}/lib/java-debug.jar";

  };
}
