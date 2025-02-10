{ lib, config, ... }:
{

  #home.stateVersion = "24.11";

  internal.javalib.enable = true;

  internal = {
    emacs.enable = true;
    terminal = "alacritty";
    linux.desktop = {
      enable = true;
      type = "niri";
    };

    modules = {
      fcitx5.enable = true;
      packages.enable = true;
    };

    vcs = {
      user = {
        name = "jojo";
        email = "a@b.com";
      };
    };
  };

}
