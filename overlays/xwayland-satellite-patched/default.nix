{ ... }:

final: prev: {
  xwayland-satellite-unstable = prev.xwayland-satellite-unstable.overrideAttrs (old: {
    patches = (old.patches or []) ++ [
      ./mixed-dpi-max-scale.patch
      ./pointer-debug.patch
      ./output-mode-scale-fix.patch
    ];
  });
}
