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

      terminal.shell.program = "zsh";
    };
  };
}
