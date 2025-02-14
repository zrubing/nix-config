{ lib, config, ... }:
{

  #home.stateVersion = "24.11";

  internal.javalib.enable = true;

  internal = {

    desktop.kde.enable = true;
    emacs.enable = true;
    terminal = "alacritty";
    gpg.enable = true;
    password-store.enable = true;

    modules = {
      fcitx5.enable = true;
      packages.enable = true;
    };

    vcs = {
      user = {
        name = "zrubing";
        email = "rubingem@gmail.com";
      };
    };
  };

}
