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
  };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      # view image
      imv

      # claude sandbox
      socat
      bubblewrap

      lsof

      grim
      satty

      jujutsu

      nautilus
      pkgs-unstable.cherry-studio
      redisinsight

      mongodb-compass

      feishu
      conda
      vscode
      ollama-rocm
      # for aider
      python312Packages.playwright
      code-cursor
      mysql84
      wireshark-qt
      pkgs-unstable.tdlib
      pkgs-unstable.localsend
      #pkgs.${namespace}.aider
      pkgs.aider-chat
      #pkgs-unstable.aider-chat
      #pkgs-unstable.claude-code
      pkgs.${namespace}.claude-code
      pkgs-nix-ai.claude-code-router
      pkgs-nix-ai.codex
      pkgs-nix-ai.openskills
      pkgs-nix-ai.beads
      pkgs-nix-ai.catnip
      pkgs-nix-ai.opencode
      pkgs-nix-ai.coding-agent-search
      #pkgs-nix-ai.gemini-cli
      pkgs-nix-ai.claude-code-acp
      pkgs-nix-ai.openspec
      #pkgs.${namespace}.trojan-go
      pkgs.${namespace}.emacs-lsp-proxy
      pkgs-unstable.mise
      pkgs.${namespace}.wl-ocr
      pkgs-nix-ai.eca
      tesseract
      pkgs-unstable.tailscale
      pkgs-unstable.dbeaver-bin
      devenv
      devpod
      devbox
      sioyek
      libreoffice
      pkgs-unstable.zed-editor
      pkgs-unstable.wpsoffice

      libnotify

    ];

    programs = {
      direnv = {
        enable = true;
        enableBashIntegration = true;
        enableZshIntegration = true;
        nix-direnv.enable = true;
      };
    };

    # 创建自定义桌面项
    xdg.desktopEntries.mongodb-compass = {
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

}
