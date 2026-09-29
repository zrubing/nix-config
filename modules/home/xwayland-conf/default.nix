{ config, namespace, ... }:

let
  # ── 多屏 X11 DPI ──
  # X11 全局 scale = 所有输出 scale 的最大值（补丁行为，见 overlays/xwayland-satellite），
  # 从 internal.desktop.outputs 派生，不要在别处再写一份字面量。
  # 匹配的 dpi = 96 × scale（当前 1.75 → 168）。
  # 副屏 HDMI-A-1（scale 1.0）复用同一套 X11 像素、由 niri 降采样，不单独设 dpi。
  # 上游自 0.8.3 起（PR #477）也会按该 scale 自己设 Xft.dpi，
  # 这里显式设成同一个值，不依赖上游行为。
  xftDpi = builtins.floor (config.${namespace}.desktop.x11Scale * 96);
  cursorSize = 32;
in
{
  # X resources 只有这一个来源：home-manager 生成 ~/.Xresources，
  # 由 modules/home/xwayland-satellite 的 xrdb.service 在 Xwayland 起来之后用
  # `xrdb -load` 装载（-load 是 xrdb 的默认语义：替换而非合并）。
  #
  # 不要再另生成第二份 Xresources 文件。之前那份只含 Xft.dpi + Xcursor.size，
  # 却由同一个 service 以替换语义装载，会把这里的 antialias / hinting /
  # hintstyle / rgba 全部抹掉。
  xresources.properties = {
    "Xft.dpi" = xftDpi;
    "Xft.antialias" = true;
    "Xft.hinting" = true;
    "Xft.hintstyle" = "hintslight";
    "Xft.rgba" = "rgb";
    "Xcursor.size" = cursorSize;
  };
}
