{
  lib,
  config,
  options,
  pkgs,
  ...
}:

let
  cfg = config.xwayland;
in
{

  options.xwayland = {

    x-resources = {
      text = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        description = "text of .Xresources";
        default = null;
      };
      source = lib.mkOption {
        type = lib.types.path;
        description = "path of .Xresources";
      };
    };
    scaling = {
      enable = lib.mkEnableOption "scaling";
      factor = lib.mkOption {
        type = lib.types.numbers.between 1 100;
        default = 1;
      };
      cursor = {
        enable = lib.mkEnableOption "scaling cursor";
        size = lib.mkOption {
          type = lib.types.number;
          default = 24;
        };
      };

    };

  };

  config = {
    # xwayland.x-resources = rec {
    #   text = ''
    #     Xft.dpi: ${toString (builtins.ceil (96 * 2))}
    #     Xcursor.size: ${toString 24}
    #   '';
    #   source = lib.mkIf (text != null) (
    #     lib.mkDerivedConfig options.xwayland.x-resources.text (pkgs.writeText ".Xresources")
    #   );
    # };
    # # 设置系统级的 X resources
    # xresources.properties = {
    #   # --- 关键设置 ---
    #   # 从 192 (2x 缩放) 开始尝试
    #   "Xft.dpi" = 192;

    #   # --- 其他推荐的字体相关设置 (可选但建议) ---
    #   "Xft.antialias" = true; # 开启抗锯齿
    #   "Xft.hinting" = true; # 开启微调
    #   "Xft.hintstyle" = "hintslight"; # 微调风格 (可选值: hintnone, hintslight, hintmedium, hintfull)
    #   "Xft.rgba" = "rgb"; # 子像素渲染顺序 (通常是 rgb, 根据你的显示器可能不同)
    # };

  };
}
