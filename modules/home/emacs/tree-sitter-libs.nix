{
  config,
  lib,
  pkgs,
  namespace,
  inputs,
  system,
  ...
}:
with lib;
let
  hm = config.lib;
in
{
  config = {
    xdg.configFile = {
      "tree-sitter-libs/libtree-sitter-java.so".source =
        "${pkgs.tree-sitter-grammars.tree-sitter-java.outPath}/parser";

    };
  };
}
