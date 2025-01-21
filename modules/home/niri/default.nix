{ pkgs, config, ... }: {

  home.file.".config/niri/config.kdl".source = ./config.kdl;
}
