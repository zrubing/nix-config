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

    cli.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable general CLI development and troubleshooting tools.";
    };

    infra.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable infrastructure / cloud / container related tools.";
    };

    nix.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Nix development tools.";
    };

    doc.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable documentation and text processing tools.";
    };

    cCpp.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable C/C++ toolchain.";
    };

    python.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Python development toolchain and libraries.";
    };

    rust.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Rust development toolchain.";
    };

    go.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Go development toolchain.";
    };

    java.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Java development toolchain.";
    };

    shell.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable shell scripting tools.";
    };

    web.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Node.js / TypeScript / web development tools.";
    };

    lisp.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Lisp-family language tools.";
    };

    miscLang.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable assorted language-specific formatters / tools.";
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
    xdg.configFile = lib.mkMerge [
      (lib.mkIf cfg.web.enable {
        "lsp-bridge-lib/typescript-lib" = {
          source = "${pkgs.nodePackages.typescript}/lib/node_modules/typescript/lib";
          recursive = true;
        };
      })
    ];

    home.packages =
      with pkgs;
      lib.flatten [
        (lib.optionals cfg.cli.enable [
          trickle
          pv
          llm
          aichat
          btop
          pueue
          dnsutils
          binutils
          graphicsmagick
          sysdig
          bcc
          ast-grep
          pkg-config
          unzip
          universal-ctags
          proselint
          fzf
          gdu
          (ripgrep.override {
            withPCRE2 = true;
          })
        ])

        (lib.optionals cfg.infra.enable [
          pnpm

          woodpecker-cli
          kubeseal
          k9s
          kubectl
          kubie
          telepresence2
          pkgs.${namespace}.tramp-rpc-server
          pkgs.${namespace}.pexpect-cli
          pkgs.${namespace}.claude-md
          xdg-utils
          vips
          actionlint
          hadolint
          sqlfluff
          buf
        ])

        (lib.optionals cfg.nix.enable [
          nix-direnv
          direnv
          nixfmt-rfc-style
          statix
          deadnix
          alejandra
          nickel
          jsonnet
        ])

        (lib.optionals cfg.doc.enable [
          glow
          pandoc
          pkgs-unstable.hugo
        ])

        (lib.optionals cfg.cCpp.enable [
          cmake
          gnumake
          checkmake
          gcc
          gdb
          clang-tools
          lldb
        ])

        (lib.optionals cfg.python.enable [
          pkgs-unstable.ty
          (python312.withPackages (
            ps: with ps; [
              paddleocr
              pipdeptree
              ruff
              black
              jupyter
              ipython
              pandas
              requests
              pyquery
              pyyaml
              boto3
              epc
              orjson
              sexpdata
              six
              setuptools
              paramiko
              rapidfuzz
              watchdog
              packaging
              networkx
              pygments
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
        ])

        (lib.optionals cfg.rust.enable [
          pkgs-unstable.rustc
          pkgs-unstable.rustup
        ])

        (lib.optionals cfg.go.enable [
          go
          gomodifytags
          iferr
          impl
          gotools
          delve
        ])

        (lib.optionals cfg.java.enable [
          javaPackages.compiler.temurin-bin.jdk-25
          leiningen
          google-java-format
          gradle
          maven
          spring-boot-cli
          google-antigravity
        ])

        (lib.optionals cfg.shell.enable [
          stylua
          shellcheck
          shfmt
        ])

        (lib.optionals cfg.web.enable [
          nodePackages.nodejs
          nodePackages.typescript
        ])

        (lib.optionals cfg.lisp.enable [
          guile
          racket-minimal
          fnlfmt
        ])

        (lib.optionals cfg.miscLang.enable [
          verible
        ])

        (lib.optionals cfg.vscodeTools.enable [
          vscode-extensions.vadimcn.vscode-lldb.adapter
          nodePackages.vscode-langservers-extracted
        ])

        (lib.optionals cfg.languageServers.enable [
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
        ])

        (lib.optionals cfg.gui.enable [
          xfce.catfish
          firefox
          pkgs-unstable.google-chrome
        ])
      ];
  };
}
