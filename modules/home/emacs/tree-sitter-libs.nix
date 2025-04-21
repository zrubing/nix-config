{
  lib,
  pkgs,
  ...
}:
with lib;
let
  grammars = pkgs.tree-sitter-grammars;

  # Map library filename suffix to the corresponding grammar package
  grammarMap = {
    rust = grammars.tree-sitter-rust;
    php = grammars.tree-sitter-php;
    java = grammars.tree-sitter-java;
    vue = grammars.tree-sitter-vue;
    typescript = grammars.tree-sitter-typescript;
    tsx = grammars.tree-sitter-tsx;
    javascript = grammars.tree-sitter-javascript;
    css = grammars.tree-sitter-css;
    scss = grammars.tree-sitter-scss;
    # Special cases for markdown: the original config swapped these
    markdown = grammars.tree-sitter-markdown-inline;
    "markdown-inline" = grammars.tree-sitter-markdown;
    html = grammars.tree-sitter-html;
    python = grammars.tree-sitter-python;
    json = grammars.tree-sitter-json;
    yaml = grammars.tree-sitter-yaml;
  };

in
{
  config = {
    # Generate xdg config entries for each grammar in the map
    xdg.configFile = mapAttrs' (name: grammarPkg: {
      # The key for the attribute set, e.g., "tree-sitter-libs/libtree-sitter-java.so"
      name = "tree-sitter-libs/libtree-sitter-${name}.so";
      # The value for the attribute set, e.g., { source = ".../parser"; }
      value = { source = "${grammarPkg.outPath}/parser"; };
    }) grammarMap;
  };
}
