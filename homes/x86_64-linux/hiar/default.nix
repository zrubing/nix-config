{
  lib,
  config,
  pkgs,
  inputs,
  system,
  namespace,
  ...
}:
let
  pkgs-nix-ai = inputs.llm-agents.packages.${system};
  llmAgentsEnabled =
    config.${namespace}.modules.packages.tools.ai.llmAgents.enable;
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

    programs.wechat.enable = true;
  };

  home.packages = lib.optionals llmAgentsEnabled [ pkgs-nix-ai.pi ];

  home.file.".pi/agent/skills/woodpecker-ci".source = ../../../.pi/skill-sources/woodpecker-ci;
  home.file.".pi/agent/skills/zli".source = ../../../.pi/skill-sources/zli;
}
