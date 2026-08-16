{
  config,
  lib,
  pkgs,
  inputs,
  system,
  namespace,
  ...
}: let
  pkgs-nix-ai = inputs.llm-agents.packages.${system};
  agent-browser = pkgs-nix-ai.agent-browser.override {
    # Override llm-agents' stale pnpm dependency hash.
    fetchPnpmDeps = args:
      pkgs.fetchPnpmDeps (args
        // {
          hash = "sha256-tkEhkGO5/JTkzySDEsTmjr5+SEXzk8V0217iQhFhfCw=";
        });
  };

  cfg = config.${namespace}.modules.packages;
in {
  options.${namespace}.modules.packages = {
    enable = lib.mkEnableOption "packages";

    tools.dev.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable general development toolchain packages.";
    };
    tools.ai.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable AI coding and agent toolchain packages.";
    };
    tools.ai.llmAgents.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable packages provided by the llm-agents flake.";
    };
    tools.ai.ollama.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Ollama client packages.";
    };
    tools.network.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable networking and remote access helper packages.";
    };
    tools.database.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable database client and management packages.";
    };
    tools.office.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable office/document desktop applications.";
    };

    gui.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable GUI desktop applications in package set.";
    };
    emacsTools.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Emacs helper tools in package set.";
    };
    ocr.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable OCR tools in package set.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs;
      [
        # claude sandbox
        socat
        bubblewrap

        lsof

        jujutsu
      ]
      ++ lib.optionals cfg.emacsTools.enable [
        pkgs.${namespace}.emacs-lsp-proxy
      ]
      ++ lib.optionals cfg.tools.dev.enable [
        conda
        pkgs.unstable.mise
        devenv
        devpod
        devbox
        mprocs
      ]
      ++ lib.optionals cfg.tools.ai.enable [
        # for aider（暂时停用，避免无用编译）
        # python312Packages.playwright
        pkgs.unstable.tdlib
        # pkgs.${namespace}.aider
        pkgs.aider-chat
        # pkgs.unstable.aider-chat
        # pkgs.unstable.claude-code
        pkgs.${namespace}.zli
        pkgs.${namespace}.chrome-devtools-mcp
      ]
      ++ lib.optionals (cfg.tools.ai.enable && cfg.tools.ai.ollama.enable) [
        ollama-rocm
      ]
      ++ lib.optionals (cfg.tools.ai.enable && cfg.tools.ai.llmAgents.enable) [
        #pkgs.${namespace}.claude-code
        #pkgs-nix-ai.claude-code-router
        pkgs-nix-ai.pi
        #pkgs-nix-ai.omp
        pkgs-nix-ai.codex
        pkgs-nix-ai.dsh
        pkgs-nix-ai.semble
        pkgs-nix-ai.workmux
        pkgs-nix-ai.openskills
        #pkgs-nix-ai.beads
        #pkgs-nix-ai.catnip
        pkgs-nix-ai.opencode
        pkgs-nix-ai.but
        pkgs-nix-ai.agent-browser
        #pkgs-nix-ai.coding-agent-search
        #pkgs-nix-ai.claude-code-acp
        pkgs-nix-ai.openspec
        pkgs-nix-ai.cc-switch-cli
        #pkgs.${namespace}.trojan-go
        pkgs-nix-ai.eca
      ]
      ++ lib.optionals cfg.tools.network.enable [
        pkgs.unstable.tailscale
        sshuttle
        mirrord
      ]
      ++ lib.optionals cfg.tools.database.enable [
        mysql84
      ]
      ++ lib.optionals cfg.ocr.enable [
        pkgs.${namespace}.wl-ocr
        tesseract
      ]
      ++ lib.optionals cfg.gui.enable (with pkgs;
        [
          # view image
          imv
          grim
          satty
          pkgs.unstable.cherry-studio
          feishu
          vscode
          code-cursor
          wireshark
          pkgs.unstable.localsend
          sioyek
          pkgs.unstable.zed-editor
          libnotify
        ]
        ++ lib.optionals cfg.tools.database.enable [
          # redisinsight 先停用，避免本地编译 redisinsight/nodejs-slim
          mongodb-compass
          pkgs.unstable.dbeaver-bin
        ]
        ++ lib.optionals cfg.tools.office.enable [
          libreoffice
          pkgs.unstable.wpsoffice
        ]);

    programs = {
      direnv = {
        enable = true;
        enableBashIntegration = true;
        enableZshIntegration = true;
        nix-direnv.enable = true;
      };
    };

    xdg.desktopEntries = lib.mkIf (cfg.gui.enable && cfg.tools.database.enable) {
      # 创建自定义桌面项
      mongodb-compass = {
        name = "MongoDB Compass";
        exec = "env XDG_CURRENT_DESKTOP=GNOME mongodb-compass --password-store=gnome-libsecret --ignore-additional-command-line-flags %U";
        icon = "mongodb-compass";
        comment = "MongoDB GUI";
        categories = [
          "Development"
          "Database"
        ];
        terminal = false;
      };
    };
  };
}
