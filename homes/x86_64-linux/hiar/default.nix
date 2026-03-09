{
  lib,
  pkgs,
  inputs,
  system,
  ...
}:
let
  pkgs-nix-ai = inputs.llm-agents.packages.${system};
in
{
  home.stateVersion = "25.11";

  snowfallorg.user.enable = true;

  internal = {
    desktop.niri.enable = true;
    noctalia.enable = true;

    emacs = {
      enable = true;
      type = "doom";
    };

    terminal = "ghostty";
    ghostty.enable = true;

    shell = {
      enable = "bash";
      provider = "GLM";
    };
    sops.enable = true;
    bash.enable = true;


    devpackages = {
      enable = true;
      gui.enable = false;
      java.enable = false;
      rust.enable = false;
      go.enable = false;
    };

    modules = {
      fcitx5.enable = true;
      fuzzel.enable = true;
    };

    programs.wechat-uos.enable = true;
  };

  home.packages = [ pkgs-nix-ai.pi ];

  home.file.".pi/agent/skills/woodpecker-ci".source = ../../../.pi/skills/woodpecker-ci;
  home.file.".pi/agent/skills/zli".source = ../../../.pi/skills/zli;
}
