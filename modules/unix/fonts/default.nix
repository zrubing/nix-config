{ config, lib, namespace, pkgs, ... }:
let cfg = config.${namespace}.fonts;
in {
  options.${namespace}.fonts.enable =
    lib.mkEnableOption "Enable installing system fonts";

  config = lib.mkIf cfg.enable {
    fonts.packages = with pkgs; [
      jetbrains-mono
      inter
      ibm-plex
      nerd-fonts.jetbrains-mono
      nerd-fonts.fira-code
    ];
  };
}
