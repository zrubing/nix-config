{ lib, config, ... }:
{

  home.stateVersion = "25.11";

  

  internal.javalib.enable = true;

  snowfallorg.user.enable = true;

  internal = {

    #desktop.kde.enable = true;
    desktop.niri.enable = true;
    emacs = {
      enable = true;
      type = "doom";
    };
    terminal = "alacritty";
    ghostty.enable = true;
    gpg.enable = true;
    password-store.enable = true;
    fish.enable = true;

    cc-proxy.enable = false;
    sops.enable = true;
    #fish.provider = "MiniMax";
    fish.provider = "GLM";
    #fish.provider = "Qwen";

    modules = {
      fcitx5.enable = true;
      fuzzel.enable = true;
      packages.enable = true;
      prettier = {
        enable = true;
        nginxPlugin = true;
      };
      # eca.enable = true;
    };

    vcs = {
      user = {
        name = "zrubing";
        email = "rubingem@gmail.com";
      };
    };
  };

}
