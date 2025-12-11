{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:

let
  cfg = config.${namespace}.prettier;
in
{
  options.${namespace}.prettier = {
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