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
      "tree-sitter-libs/libtree-sitter-vue.so".source =
        "${pkgs.tree-sitter-grammars.tree-sitter-vue.outPath}/parser";
      "tree-sitter-libs/libtree-sitter-typescript.so".source =
        "${pkgs.tree-sitter-grammars.tree-sitter-typescript.outPath}/parser";
      "tree-sitter-libs/libtree-sitter-tsx.so".source =
        "${pkgs.tree-sitter-grammars.tree-sitter-tsx.outPath}/parser";
      "tree-sitter-libs/libtree-sitter-javascript.so".source =
        "${pkgs.tree-sitter-grammars.tree-sitter-javascript.outPath}/parser";
      "tree-sitter-libs/libtree-sitter-css.so".source =
        "${pkgs.tree-sitter-grammars.tree-sitter-css.outPath}/parser";
      "tree-sitter-libs/libtree-sitter-scss.so".source =
        "${pkgs.tree-sitter-grammars.tree-sitter-scss.outPath}/parser";
      "tree-sitter-libs/libtree-sitter-markdown.so".source =
        "${pkgs.tree-sitter-grammars.tree-sitter-markdown.outPath}/parser";
      "tree-sitter-libs/libtree-sitter-html.so".source =
        "${pkgs.tree-sitter-grammars.tree-sitter-html.outPath}/parser";
      "tree-sitter-libs/libtree-sitter-python.so".source =
        "${pkgs.tree-sitter-grammars.tree-sitter-python.outPath}/parser";
      "tree-sitter-libs/libtree-sitter-json.so".source =
        "${pkgs.tree-sitter-grammars.tree-sitter-json.outPath}/parser";


    };
  };
}
