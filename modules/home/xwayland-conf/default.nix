{
  lib,
  config,
  options,
  pkgs,
  ...
}:

let
  cfg = config.xwayland;

  # ── 多屏 X11 DPI 折中值 ──
  # 主屏 eDP-1 scale=1.75 → 理想 dpi=168
  # 副屏 HDMI-A-1 scale=1.0 → 理想 dpi=96
  # 折中取 144（1.5x），两边都可接受
  # 可按需调整：168（偏向主屏）/ 96（偏向副屏）
  xftDpi = 144;
  cursorSize = 32;
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
    xwayland.x-resources = rec {
      text = ''
        Xft.dpi: ${toString xftDpi}
        Xcursor.size: ${toString cursorSize}
       '';
      source = lib.mkIf (text != null) (
        lib.mkDerivedConfig options.xwayland.x-resources.text (pkgs.writeText ".Xresources")
      );
    };
    # 设置系统级的 X resources
    #
    # 多屏 DPI 折中策略（2026-03）：
    # - eDP-1: 2880x1800, scale 1.75 → X11 app 需要 dpi ≈ 96 × 1.75 = 168 才能在此屏正常显示
    # - HDMI-A-1: 1920x1080, scale 1.0 → X11 app 需要 dpi = 96
    # - xwayland-satellite 0.8 统一使用最低 scale（1.0），所以 X11 像素在 HDMI 上 1:1 映射，
    #   在 eDP 上被 niri 按 1.75x 缩放
    # - 设为 144（1.5x）是折中值：HDMI 上略大但可用，eDP 上 144/1.75 ≈ 82 也还行
    # - 如果主要在 eDP 上用 X11 程序，可以改成 168；主要在 HDMI 上用则改成 96
    xresources.properties = {
      "Xft.dpi" = xftDpi;
      "Xft.antialias" = true;
      "Xft.hinting" = true;
      "Xft.hintstyle" = "hintslight";
      "Xft.rgba" = "rgb";
    };

  };
}
