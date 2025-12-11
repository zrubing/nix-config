{
  config,
  lib,
  pkgs,
  namespace,
  ...
 }:

let
  cfg = config.${namespace}.modules.prettier;
in
{
  options.${namespace}.modules.prettier = {
    enable = lib.mkEnableOption "prettier";
    
    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "List of prettier plugins to include";
    };

    nginxPlugin = lib.mkEnableOption "prettier nginx plugin";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      (pkgs.prettier-with-plugins {
        enabled = cfg.plugins ++ (lib.optionals cfg.nginxPlugin [
          (pkgs.callPackage ../../../packages/prettier-plugin-nginx { })
        ]);
      })
    ];
  };
}