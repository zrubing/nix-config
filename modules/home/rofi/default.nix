{ config, namespace, ... }: {
  programs.rofi = {
    font = "JetBrainsMono Nerd Font Medium 16";
    terminal = "${config.${namespace}.terminal}";
    theme = let inherit (config.lib.formats.rasi) mkLiteral;
    in {
      "*" = {
        border = 0;
        margin = 0;
        padding = 0;
        spacing = 0;
      };
      mainbox = {
        border = 4;
        border-radius = 8;
      };
      inputbar = { children = map mkLiteral [ "prompt" "entry" ]; };
      entry = { padding = mkLiteral "12px 3px"; };
      prompt = { padding = mkLiteral "12px 16px 12px 12px"; };
      listview.lines = 10;
      element.children = map mkLiteral [ "element-icon" "element-text" ];
      element-icon.padding = mkLiteral "10px";
      element-text.padding = mkLiteral "10px";
    };
  };
}
