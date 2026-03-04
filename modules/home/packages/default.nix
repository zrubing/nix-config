{
  config,
  lib,
  pkgs,
  inputs,
  system,
  namespace,
  ...
}:
let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit system;
    config.allowUnfree = true;
  };

  pkgs-nix-ai = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};

  cfg = config.${namespace}.modules.packages;
in
{

  options.${namespace}.modules.packages = {
    enable = lib.mkEnableOption "packages";
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
    home.packages = with pkgs; [
      # claude sandbox
      socat
      bubblewrap

      lsof

      jujutsu

      conda
      ollama-rocm
      # for aider
      python312Packages.playwright
      mysql84
      pkgs-unstable.tdlib
      #pkgs.${namespace}.aider
      pkgs.aider-chat
      #pkgs-unstable.aider-chat
      #pkgs-unstable.claude-code
      pkgs.${namespace}.claude-code
      pkgs-nix-ai.claude-code-router
      pkgs-nix-ai.pi
      pkgs-nix-ai.omp
      pkgs-nix-ai.codex
      pkgs-nix-ai.workmux
      pkgs-nix-ai.openskills
      pkgs-nix-ai.beads
      pkgs-nix-ai.catnip
      pkgs-nix-ai.opencode
      pkgs-nix-ai.coding-agent-search
      pkgs-nix-ai.gemini-cli
      pkgs-nix-ai.claude-code-acp
      pkgs-nix-ai.openspec
      pkgs-nix-ai.cc-switch-cli
      #pkgs.${namespace}.trojan-go
      pkgs-unstable.mise
      pkgs-nix-ai.eca
      pkgs-unstable.tailscale
      devenv
      devpod
      devbox

    ] ++ lib.optionals cfg.emacsTools.enable [
      pkgs.${namespace}.emacs-lsp-proxy
    ] ++ lib.optionals cfg.ocr.enable [
      pkgs.${namespace}.wl-ocr
      tesseract
    ] ++ lib.optionals cfg.gui.enable (with pkgs; [
      # view image
      imv
      grim
      satty
      nautilus
      pkgs-unstable.cherry-studio
      redisinsight
      mongodb-compass
      feishu
      vscode
      code-cursor
      wireshark-qt
      pkgs-unstable.localsend
      pkgs-unstable.dbeaver-bin
      sioyek
      libreoffice
      pkgs-unstable.zed-editor
      pkgs-unstable.wpsoffice
      libnotify
    ]);

    programs = {
      direnv = {
        enable = true;
        enableBashIntegration = true;
        enableZshIntegration = true;
        nix-direnv.enable = true;
      };
    };

    xdg.desktopEntries = lib.mkIf cfg.gui.enable {
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
