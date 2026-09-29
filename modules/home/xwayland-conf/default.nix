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
    # 多屏 DPI 策略：
    # - eDP-1: 2880x1800, scale 1.75 → 与此屏匹配的 dpi ≈ 96 × 1.75 = 168
    # - HDMI-A-1: 1920x1080, scale 1.0 → 复用同一套 X11 像素并降采样，不单独设 dpi
    # - X11 只有一个全局 scale，xwayland-satellite 报的就是最大值 1.75
    #   （补丁行为，见 overlays/xwayland-satellite），故匹配值是 168
    # - 自 0.8.3 起上游（PR #477，commit 324ef5d）会按该 scale 自己设 Xft.dpi=168，
    #   而下面的 xrdb 会把它覆盖掉
    # - 144（1.5x）是更早、误以为全局 scale 是 1.0 时留下的折中值，按现在的前提
    #   偏小一档；改成 168 即与 X11 几何一致
    xresources.properties = {
      "Xft.dpi" = xftDpi;
      "Xft.antialias" = true;
      "Xft.hinting" = true;
      "Xft.hintstyle" = "hintslight";
      "Xft.rgba" = "rgb";
    };

  };
}
