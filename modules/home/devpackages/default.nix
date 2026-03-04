{
  config,
  pkgs,
  inputs,
  system,
  lib,
  namespace,
  ...
}:
let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = system;
    config.allowUnfree = true;
  };
  cfg = config.${namespace}.devpackages;
in
{
  options.${namespace}.devpackages = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable development package set.";
    };

    gui.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable GUI applications in development package set.";
    };

    treeSitter.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable tree-sitter related dependencies in development package set.";
    };

    vscodeTools.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable VSCode-derived development tools.";
    };

    languageServers.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable language server packages in development package set.";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."lsp-bridge-lib/typescript-lib" = {
      source = "${pkgs.nodePackages.typescript}/lib/node_modules/typescript/lib";
      recursive = true;
    };

    home.packages =
      with pkgs;
      (
        # -*- Data & Configuration Languages -*-#
        [

          kubeseal
          k9s

          llm

          kubectl
          kubie


          aichat
          btop
          telepresence2

          pkgs.${namespace}.tramp-rpc-server

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

          # inputs.codex-nix.packages.${pkgs.stdenv.hostPlatform.system}.default

          #pkgs.${namespace}.sunloginclient
          uv
          # for emacs dirvish
          vips

          nix-direnv
          direnv
          #-- nix
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
          jsonnet
          actionlint # GitHub Actions linter

          #-- dockerfile
          hadolint # Dockerfile linter

          #-- markdown
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

            #-- python
            pkgs-unstable.ty

            # for cliphist image
            xdg-utils

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
                networkx
                pygments
                #grep-ast
                diskcache
                tiktoken
                tqdm
                gitignore-parser
                scipy
                litellm

              ] ++ lib.optionals cfg.treeSitter.enable [
                pkgs.${namespace}.grep-ast
                pkgs.${namespace}.tree-sitter-language-pack
                pkgs.${namespace}.tree-sitter-c-sharp
                pkgs.${namespace}.tree-sitter-embedded-template
                pkgs.${namespace}.tree-sitter-yaml
                tree-sitter
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
            delve # go debugger

            # -- java
            # jdk24
            javaPackages.compiler.temurin-bin.jdk-25
            leiningen

            google-java-format

            gradle
            maven
            spring-boot-cli
            # pkgs.${namespace}.java-debug #依赖总是不固定，先注释
            # pkgs.${namespace}.claude-code-proxy

            google-antigravity

            # php

            #-- lua
            stylua

            #-- bash
            shellcheck
            shfmt
            #bitcoin
          ]
        #-*- Web Development -*-#
        ++ [
          nodePackages.nodejs
          nodePackages.typescript
        ]
        # -*- Lisp like Languages -*-#
        ++ [
          guile
          racket-minimal
          fnlfmt # fennel
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
        ++ lib.optionals cfg.vscodeTools.enable [
          vscode-extensions.vadimcn.vscode-lldb.adapter
          # HTML/CSS/JSON/ESLint language servers extracted from vscode
          nodePackages.vscode-langservers-extracted
        ]
        ++ lib.optionals cfg.languageServers.enable [
          copilot-language-server
          nixd
          nil
          terraform-ls
          jsonnet-language-server
          taplo
          nodePackages.yaml-language-server
          dockerfile-language-server
          marksman
          cmake-language-server
          basedpyright
          pyright
          gopls
          lemminx
          pkgs-unstable.jdt-language-server
          intelephense
          zls
          lua-language-server
          nodePackages.bash-language-server
          pkgs.${namespace}.vue-language-server
          pkgs-unstable.typescript-language-server
          nodePackages."@tailwindcss/language-server"
          emmet-ls
          (if pkgs.stdenv.isDarwin then pkgs.emptyDirectory else pkgs-unstable.akkuPackages.scheme-langserver)
        ]
        ++ lib.optionals cfg.gui.enable [
          xfce.catfish
          firefox
          pkgs-unstable.google-chrome
        ]
      );

  };
}
