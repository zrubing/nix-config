{ pkgs, ... }:
{

  environment.systemPackages = [
    pkgs.tree-sitter-grammars.tree-sitter-java
    pkgs.tree-sitter-grammars.tree-sitter-rust
    pkgs.tree-sitter-grammars.tree-sitter-markdown
    pkgs.tree-sitter-grammars.tree-sitter-typescript
    pkgs.tree-sitter-grammars.tree-sitter-javascript
    pkgs.tree-sitter-grammars.tree-sitter-tsx
    pkgs.tree-sitter-grammars.tree-sitter-vue
  ];
}
