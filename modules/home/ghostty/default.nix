{
  lib,
  config,
  pkgs,
  namespace,
  ...
}:

let
  cfg = config.${namespace}.ghostty;

  # 根据启用的shell选择shell程序和integration
  shellCmd = if config.${namespace}.fish.enable then
    "${pkgs.fish}/bin/fish"
  else if config.${namespace}.bash.enable then
    "${pkgs.bash}/bin/bash"
  else
    "${pkgs.fish}/bin/fish";  # 默认fallback

  shellIntegration = if config.${namespace}.fish.enable then
    "fish"
  else if config.${namespace}.bash.enable then
    "bash"
  else
    "fish";  # 默认fallback
in
{
  options.${namespace}.ghostty = {
    enable = lib.mkEnableOption "Enable ghostty terminal";
  };

  config = lib.mkIf cfg.enable {
    programs.ghostty = {
      enable = true;

      settings = {
        # --- Catppuccin Mocha 主题颜色 ---
        background = "#1e1e2e";
        foreground = "#cdd6f4";
        palette = [
          "0=#45475a"
          "1=#f38ba8"
          "2=#a6e3a1"
          "3=#f9e2af"
          "4=#89b4fa"
          "5=#f5c2e7"
          "6=#94e2d5"
          "7=#a6adc8"
          "8=#585b70"
          "9=#f37799"
          "10=#89d88b"
          "11=#ebd391"
          "12=#74a8fc"
          "13=#f2aede"
          "14=#6bd7ca"
          "15=#bac2de"
        ];
        cursor-color = "#f5e0dc";
        cursor-text = "#1e1e2e";

        # --- 界面 ---
        window-padding-x = 10;
        window-padding-y = 10;
        window-decoration = false;

        # --- 字体 ---
        font-family = "JetBrains Mono Nerd Font";
        font-size = 9;
        font-thicken = true;
        font-feature = [ "calt" "liga" ];

        # --- Shell ---
        command = shellCmd;
        term = "xterm-ghostty";

        # --- 行为 ---
        confirm-close-surface = false;
        copy-on-select = true;
        shell-integration = shellIntegration;
        shell-integration-features = "sudo,title,ssh-terminfo,ssh-env";

        # --- Quick Terminal (Quake Mode) ---
        quick-terminal-position = "top";
        quick-terminal-screen = "main";
        quick-terminal-animation-duration = 0.2;

        # --- 快捷键 ---
        keybind = [
          # "super+grave=toggle_quick_terminal"  # 暂时禁用，可能导致配置验证错误
          "ctrl+x>2=new_split:down"
          "ctrl+x>3=new_split:right"
          "ctrl+x>o=goto_split:next"
          "ctrl+x>1=toggle_split_zoom"
          "ctrl+x>0=close_surface"
        ];

        # --- 鼠标 ---
        mouse-scroll-multiplier = 3.0;

        # --- 分屏透明度 ---
        unfocused-split-opacity = 0.7;
      };
    };
  };
}
