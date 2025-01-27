{ lib, config, ... }: {

  #home.stateVersion = "24.11";

  internal.javalib.enable = true;

  internal.modules = {
    fcitx5.enable = true;
    packages.enable = true;
  };

}
