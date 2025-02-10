{ options, config, lib, pkgs, namespace, ... }:
with lib;
with lib.${namespace};
let cfg = config.${namespace}.desktop.niri;
in {
  options.${namespace}.desktop.niri = with types; {
    enable =
      mkBoolOpt false "Whether or not to use niri as the desktop environment.";
  };

  config = mkIf cfg.enable {

    programs.niri.enable = true;
    ${namespace}.greetd.enable = true;
  };
}
