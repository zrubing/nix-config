{ pkgs, ... }: {
  ##################################################################################################################
  #
  # All jojo's Home Manager Configuration
  #
  ##################################################################################################################

  modules.editors.emacs = { enable = false; };

  home.linux.desktop.enable = true;

  imports = [
    ../../home/core.nix

    ../../home/fcitx5
    ../../home/i3
    ../../home/programs
    ../../home/programs/editors/packages.nix
    ../../home/programs/editors/emacs.nix
    ../../home/rofi
    ../../home/shell

    ../../home/wayland-desktop
  ];

  programs.git = {
    userName = "jojo";
    userEmail = "a@b.com";
  };
}
