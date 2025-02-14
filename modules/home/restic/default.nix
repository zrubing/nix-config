{
  pkgs,
  config,
  lib,
  namespace,
  ...
}:
with lib;
with lib.${namespace};
let
  cfg = config.${namespace}.restic;
in
{
  options.${namespace}.restic = with types; {
    enable = mkBoolOpt false "Enable restic backup support";
  };

  config = mkIf cfg.enable {

    home.packages = with pkgs; [
      rclone
    ];

  };

}
