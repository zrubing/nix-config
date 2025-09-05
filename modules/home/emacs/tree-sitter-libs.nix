{
  lib,
  pkgs,
  inputs,
  system,
  ...
}:
with lib;
let
  grammars = pkgs.tree-sitter-grammars;
  # Map library filename suffix to the corresponding grammar package
  grammarMap = {
    phpdoc = inputs.tree-sitter-grammars.packages.${system}.tree-sitter-phpdoc;
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
    markdown = grammars.tree-sitter-markdown;
    "markdown-inline" = grammars.tree-sitter-markdown-inline;
    html = grammars.tree-sitter-html;
    python = grammars.tree-sitter-python;
    json = grammars.tree-sitter-json;
    yaml = grammars.tree-sitter-yaml;
    c = grammars.tree-sitter-c;
    cpp = grammars.tree-sitter-cpp;
    go = grammars.tree-sitter-go;
    bash = grammars.tree-sitter-bash;
    ruby = grammars.tree-sitter-ruby;
    toml = grammars.tree-sitter-toml;
    jsdoc = grammars.tree-sitter-jsdoc;
  };

  grammarFiles = mapAttrs' (name: grammarPkg: {
    name = "tree-sitter-libs/libtree-sitter-${name}.so";
    value = {
      source = 
        if name == "phpdoc" 
        then "${grammarPkg}/lib/libtree-sitter-phpdoc.so"
        else "${grammarPkg.outPath}/parser";
    };
  }) grammarMap;

in
{
  config = {
    xdg.configFile = grammarFiles;

  };

}
