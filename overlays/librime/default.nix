{
  channels,
  ...
}:

final: prev: {
  librime-lua = prev.librime-lua.override {
    lua = channels.nixpkgs.lua5_4_compat;
  };

  librime = let
    # 使用当前覆盖后的 librime-lua
    librime-lua' = final.librime-lua;
  in
    (prev.librime.override {
      plugins = [
        librime-lua'
        channels.nixpkgs.librime-octagram
      ];
    }).overrideAttrs
      (old: {
        buildInputs = (old.buildInputs or [ ]) ++ [ channels.nixpkgs.lua5_4_compat ];
      });
}
