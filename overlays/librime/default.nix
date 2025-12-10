{
  channels,
  ...
}:

final: prev: {
  librime =
    (prev.librime.override {
      plugins = with channels.nixpkgs; [
        librime-lua
        librime-octagram
      ];
    }).overrideAttrs
      (old: {
        buildInputs = (old.buildInputs or [ ]) ++ [ channels.nixpkgs.luajit ]; # 用luajit
      });
}
