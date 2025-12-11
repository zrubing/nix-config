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
    enable = lib.mkEnableOption "prettier with nginx plugin";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      (pkgs.prettier.override {
        plugins = [
          (pkgs.callPackage ../../packages/prettier-plugin-nginx { })
        ];
      })
    ];
  };
}