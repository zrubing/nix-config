# xwayland-satellite 0.8.3（取自 nixpkgs-unstable）+ 混合 DPI 的 max-scale 补丁。
#
# 为什么不再用 niri-flake 的 `xwayland-satellite-unstable`：
# niri-flake 上游自 2026-08-04 起停更（sodiboo 本人最后一次提交是 2026-01-04，
# 之后全是机器人 lock 更新），它自带的 xwayland-satellite input 冻在 0.8.2
# （Supreeeme 主线 2026-07-22）。nixpkgs-unstable 目前是 0.8.3，直接复用它的
# 包定义即可拿到上游三个月的修复，且比 niri-flake 多 man page / libxcb。
#
# 覆盖 `pkgs.xwayland-satellite` 本身而不是另起 `-patched` 之类的名字：
# 同一概念只留一个属性，避免再出现“到底在用哪个包”的歧义。
{
  channels,
  ...
}:
final: prev: {
  xwayland-satellite = channels.nixpkgs-unstable.xwayland-satellite.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./mixed-dpi-max-scale.patch ];
  });
}
