{ lib, config, ... }:
{

  #home.stateVersion = "24.11";

  internal.javalib.enable = true;

  internal = {

    #desktop.kde.enable = true;
    desktop.niri.enable = true;
    emacs = {
      enable = true;
      type = "doom";
    };
    terminal = "alacritty";
    gpg.enable = true;
    password-store.enable = true;
    fish.enable = true;

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
