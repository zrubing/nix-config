{ config, lib, namespace, pkgs, ... }:
let cfg = config.${namespace}.fonts;
in {
  imports = [ ../../unix/fonts ];

  config.fonts = lib.mkIf cfg.enable {

    packages = with pkgs; [
      dejavu_fonts
      # icon fonts
      material-design-icons

      # normal fonts
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-emoji

      # nerdfonts
      (nerdfonts.override { fonts = [ "FiraCode" "JetBrainsMono" ]; })
    ];

    # use fonts specified by user rather than default ones
    enableDefaultPackages = false;

    # user defined fonts
    # the reason there's Noto Color Emoji everywhere is to override DejaVu's
    # B&W emojis that would sometimes show instead of some Color emojis
    fontconfig.defaultFonts = {
      serif = [ "Noto Serif CJK SC" "Noto Serif" "Noto Color Emoji" ];
      sansSerif = [ "Noto Sans CJK SC" "Noto Sans" "Noto Color Emoji" ];
      monospace = [ "JetBrainsMono Nerd Font" "Noto Color Emoji" ];
      emoji = [ "Noto Color Emoji" ];
    };

  };
}
