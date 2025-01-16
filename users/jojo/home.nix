{ pkgs, ... }: {
  ##################################################################################################################
  #
  # All jojo's Home Manager Configuration
  #
  ##################################################################################################################

  imports = [
    ../../home/core.nix

    ../../home/fcitx5
    ../../home/i3
    ../../home/programs
    ../../home/programs/editors/emacs.nix
    ../../home/rofi
    ../../home/shell
  ];

  programs.git = {
    userName = "jojo";
    userEmail = "a@b.com";
  };
}
