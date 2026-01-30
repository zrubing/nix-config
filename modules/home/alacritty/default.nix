{
  lib,
  config,
  pkgs,
  namespace,
  ...
}:

let
  # 根据启用的shell选择shell程序
  shellProgram = if config.${namespace}.fish.enable then
    "${pkgs.fish}/bin/fish"
  else if config.${namespace}.bash.enable then
    "${pkgs.bash}/bin/bash"
  else
    "${pkgs.fish}/bin/fish";  # 默认fallback
in
{
  programs.alacritty = {
    enable = true;
    settings = {
      env.WINIT_X11_SCALE_FACTOR = "1";

      font = {
        size = 9.0;
        normal = {
          family = "JetBrains Mono";
          style = "Regular";
        };
      };

      window = {
        padding = {
          x = 2;
          y = 2;
        };
        dynamic_padding = true;
        decorations = "None";
        dynamic_title = true;
      };

      terminal.shell.program = shellProgram;
    };
  };
}
