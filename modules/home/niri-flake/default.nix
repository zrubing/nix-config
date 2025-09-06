{
  config,
  lib,
  namespace,
  ...
}:
with lib;
with lib.${namespace};
let
  cfg = config.${namespace}.niri-flake;
in
{
  options.${namespace}.niri-flake = with types; {
    enable = mkBoolOpt false "Enable niri-flake config";
  };

  config = mkIf cfg.enable {


  };

}
