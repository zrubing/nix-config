{
  pkgs,
  inputs,
  system,
  namespace,
  ...
}:
let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = system;
    config.allowUnfree = true;
  };
in
{
  config = {
    xdg.configFile."lsp-bridge-lib/typescript-lib" = {
      source = "${pkgs.nodePackages.typescript}/lib/node_modules/typescript/lib";
      recursive = true;
    };

    home.packages =
      with pkgs;
      (
        # -*- Data & Configuration Languages -*-#
        [

          pkgs.${namespace}.pexpect-cli
          pkgs.${namespace}.claude-md
          pueue
          dnsutils
          binutils
          graphicsmagick
          sysdig
          bcc
          ast-grep

          pkg-config
          unzip

          xfce.catfish

          # inputs.codex-nix.packages.${pkgs.stdenv.hostPlatform.system}.default

          #pkgs.${namespace}.sunloginclient
          firefox
          pkgs-unstable.google-chrome
          uv
          # for emacs dirvish
          vips

          copilot-language-server

          nix-direnv
          direnv
          #-- nix
          nixd
          nil
          nixfmt-rfc-style
          # rnix-lsp
          # nixd
          statix # Lints and suggestions for the nix programming language
          deadnix # Find and remove unused code in .nix source files
          alejandra # Nix Code Formatter

          #-- nickel lang
          nickel

          #-- json like
          # terraform  # install via brew on macOS
          terraform-ls
          jsonnet
          jsonnet-language-server
          taplo # TOML language server / formatter / validator
          nodePackages.yaml-language-server
          actionlint # GitHub Actions linter

          #-- dockerfile
          hadolint # Dockerfile linter
          dockerfile-language-server

          #-- markdown
          marksman # language server for markdown
          glow # markdown previewer
          pandoc # document converter
          pkgs-unstable.hugo # static site generator

          universal-ctags

          #-- sql
          sqlfluff

          #-- protocol buffer
          buf # linting and formatting
        ]
        ++
          #-*- General Purpose Languages -*-#
          [
            #-- c/c++
            cmake
            cmake-language-server
            gnumake
            checkmake
            # c/c++ compiler, required by nvim-treesitter!
            gcc
            gdb
            # c/c++ tools with clang-tools, the unwrapped version won't
            # add alias like `cc` and `c++`, so that it won't conflict with gcc
            # llvmPackages.clang-unwrapped
            clang-tools
            lldb
            vscode-extensions.vadimcn.vscode-lldb.adapter # codelldb - debugger

            #-- python
            basedpyright
            pkgs-unstable.ty

            # for cliphist image
            xdg-utils

            pyright # python language server
            (python312.withPackages (
              ps: with ps; [
                paddleocr
                pipdeptree

                ruff

                black # python formatter
                # debugpy

                # my commonly used python packages
                jupyter
                ipython
                pandas
                requests
                pyquery
                pyyaml
                boto3

                ## emacs's lsp-bridge dependenciesge
                epc
                orjson
                sexpdata
                six
                setuptools
                paramiko
                rapidfuzz
                watchdog
                packaging

                ## emacs emigo dependencies
                pkgs.${namespace}.grep-ast
                pkgs.${namespace}.tree-sitter-language-pack
                pkgs.${namespace}.tree-sitter-c-sharp
                pkgs.${namespace}.tree-sitter-embedded-template
                pkgs.${namespace}.tree-sitter-yaml
                tree-sitter
                networkx
                pygments
                #grep-ast
                diskcache
                tiktoken
                tqdm
                gitignore-parser
                scipy
                litellm

              ]
            ))

            #-- rust
            # we'd better use the rust-overlays for rust development
            pkgs-unstable.rustc
            pkgs-unstable.rustup
            #pkgs-unstable.rust-analyzer
            #pkgs-unstable.cargo # rust package manager
            #pkgs-unstable.rustfmt
            #pkgs-unstable.clippy # rust linter

            #-- golang
            go
            gomodifytags
            iferr # generate error handling code for go
            impl # generate function implementation for go
            gotools # contains tools like: godoc, goimports, etc.
            gopls # go language server
            delve # go debugger

            # -- java
            # jdk24
            javaPackages.compiler.temurin-bin.jdk-25
            leiningen

            google-java-format

            gradle
            maven
            spring-boot-cli
            lemminx
            # pkgs.${namespace}.java-debug #依赖总是不固定，先注释
            # pkgs.${namespace}.claude-code-proxy
            pkgs-unstable.jdt-language-server

            google-antigravity

            # php
            intelephense

            #-- zig
            zls

            #-- lua
            stylua
            lua-language-server

            #-- bash
            nodePackages.bash-language-server
            shellcheck
            shfmt
            #bitcoin
          ]
        #-*- Web Development -*-#
        ++ [
          # vue
          pkgs.${namespace}.vue-language-server

          nodePackages.nodejs
          nodePackages.typescript
          pkgs-unstable.typescript-language-server
          # HTML/CSS/JSON/ESLint language servers extracted from vscode
          nodePackages.vscode-langservers-extracted
          nodePackages."@tailwindcss/language-server"
          emmet-ls
        ]
        # -*- Lisp like Languages -*-#
        ++ [
          guile
          racket-minimal
          fnlfmt # fennel
          (if pkgs.stdenv.isDarwin then pkgs.emptyDirectory else pkgs-unstable.akkuPackages.scheme-langserver)
        ]
        ++ [
          proselint # English prose linter

          #-- verilog / systemverilog
          verible

          #-- Optional Requirements:
          # nodePackages.prettier # common code formatter - now provided by prettier module

          fzf
          gdu # disk usage analyzer, required by AstroNvim
          (ripgrep.override {
            withPCRE2 = true;
          }) # RECURSIVELY SEARCHES DIRECTORIES FOR A REGEX PATTERN
        ]
      );

  };
}
