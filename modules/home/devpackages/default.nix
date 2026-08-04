{
  config,
  pkgs,
  lib,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.devpackages;

  # 分组清单：各分组的 enable option 由此生成，新增分组只需在此加一行
  groups = {
    cli = "general CLI development and troubleshooting tools";
    infra = "infrastructure / cloud / container related tools";
    nix = "Nix development tools";
    doc = "documentation and text processing tools";
    cCpp = "C/C++ toolchain";
    python = "Python development toolchain and libraries";
    rust = "Rust development toolchain";
    go = "Go development toolchain";
    java = "Java development toolchain";
    shell = "shell scripting tools";
    web = "Node.js / TypeScript / web development tools";
    lisp = "Lisp-family language tools";
    miscLang = "assorted language-specific formatters / tools";
    gui = "GUI applications in development package set";
    treeSitter = "tree-sitter related dependencies in development package set";
    vscodeTools = "VSCode-derived development tools";
    languageServers = "language server packages in development package set";
  };

  mkEnable = desc: lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable ${desc}.";
  };
in
{
  options.${namespace}.devpackages = {
    enable = mkEnable "the development package set";
  } // lib.mapAttrs' (name: desc: lib.nameValuePair name { enable = mkEnable desc; }) groups;

  config = lib.mkIf cfg.enable {
    xdg.configFile = lib.mkIf cfg.web.enable {
      "lsp-bridge-lib/typescript-lib" = {
        source = "${pkgs.typescript}/lib/node_modules/typescript/lib";
        recursive = true;
      };
    };

    home.sessionPath = lib.mkIf cfg.infra.enable [
      "$HOME/.krew/bin"
    ];

    home.packages =
      with pkgs;
      lib.flatten [
        (lib.optionals cfg.cli.enable [
          mongosh
          uv
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
          pkgs.unstable.pnpm
          postgresql
          flyway

          woodpecker-cli
          kubeseal
          kubectl
          (symlinkJoin {
            name = "kubectl-krew-wrapper";
            paths = [ krew ];
            postBuild = ''
              ln -s $out/bin/krew $out/bin/kubectl-krew
            '';
          })
          kubelogin-oidc
          kubie
          telepresence2
          pkgs.${namespace}.tramp-rpc-server
          pkgs.${namespace}.pexpect-cli
          pkgs.${namespace}.claude-md
          pkgs.${namespace}.java-debug
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
          nixfmt
          statix
          deadnix
          alejandra
          nickel
          jsonnet
        ])

        (lib.optionals cfg.doc.enable [
          glow
          pandoc
          pkgs.unstable.hugo
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
          pkgs.unstable.ty
          (python312.withPackages (
            ps: with ps; [
              # paddleocr 先停用，避免拉入 pdf2docx/pymupdf/mupdf 重依赖链
              pipdeptree
              ruff
              black
              # jupyter 先停用，减少重型 Python 依赖链
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
              # litellm 先停用，避免拉入 tokenizers/huggingface-hub/hf-xet
            ] ++ lib.optionals cfg.treeSitter.enable [
              # 扩展包已停用（避免无用构建和依赖报错），仅保留本体
              tree-sitter
            ]
          ))
        ])

        (lib.optionals cfg.rust.enable [
          pkgs.unstable.rustc
          pkgs.unstable.rustup
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
          # google-antigravity 先停用，避免引入 antigravity-nix 的过时 xorg warning
        ])

        (lib.optionals cfg.shell.enable [
          stylua
          shellcheck
          shfmt
        ])

        (lib.optionals cfg.web.enable [
          nodejs
          typescript
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
          vscode-langservers-extracted
        ])

        (lib.optionals cfg.languageServers.enable [
          copilot-language-server
          nixd
          nil
          terraform-ls
          jsonnet-language-server
          taplo
          yaml-language-server
          dockerfile-language-server
          marksman
          cmake-language-server
          basedpyright
          pyright
          gopls
          lemminx
          pkgs.unstable.jdt-language-server
          intelephense
          zls
          lua-language-server
          bash-language-server
          pkgs.unstable.vue-language-server
          pkgs.unstable.typescript-language-server
          tailwindcss-language-server
          emmet-ls
          (if pkgs.stdenv.isDarwin then pkgs.emptyDirectory else pkgs.unstable.akkuPackages.scheme-langserver)
        ])

        (lib.optionals cfg.gui.enable [
          pkgs.catfish
          firefox
          obs-studio
          pkgs.unstable.google-chrome
        ])
      ];
  };
}
