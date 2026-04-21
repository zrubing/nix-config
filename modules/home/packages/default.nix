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
    config = {
      allowUnfree = true;
      permittedInsecurePackages = [
        "electron-38.8.4"
      ];
    };
  };

  pkgs-nix-ai = inputs.llm-agents.packages.${system};

  cfg = config.${namespace}.modules.packages;
in
let
  flakeLock = builtins.fromJSON (builtins.readFile ../../../flake.lock);
  guardrailsRev = flakeLock.nodes."pi-guardrails-src".locked.rev;
  guardrailsPackage = "git:github.com/zrubing/pi-guardrails#${guardrailsRev}";
in
{

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
    home.file.".pi/agent/skills/woodpecker-ci".source = ../../../.pi/skill-sources/woodpecker-ci;
    home.file.".pi/agent/skills/zli".source = ../../../.pi/skill-sources/zli;

    # Caveman skills
    home.file.".pi/agent/skills/caveman".source = "${inputs.caveman-skills}/skills/caveman";
    home.file.".pi/agent/extensions/guardrails.json".source = ../../../.pi/extensions/guardrails.json;

    home.activation.configurePiGuardrailsFork = config.lib.dag.entryAfter [ "writeBoundary" ] ''
      settings_file="$HOME/.pi/agent/settings.json"
      ${pkgs.coreutils}/bin/mkdir -p "$HOME/.pi/agent"

      if [ ! -f "$settings_file" ]; then
        cat > "$settings_file" <<'EOF'
      {
        "packages": []
      }
      EOF
      fi

      ${pkgs.jq}/bin/jq \
        --arg forkPkg '${guardrailsPackage}' \
        '
        .packages = (
          ((.packages // [])
            | map(select(. != "npm:@aliou/pi-guardrails" and (. | startswith("git:github.com/zrubing/pi-guardrails") | not))))
          + [$forkPkg]
          | unique
        )
        ' "$settings_file" > "$settings_file.tmp"

      ${pkgs.coreutils}/bin/mv "$settings_file.tmp" "$settings_file"
    '';

    home.packages = with pkgs; [
      # claude sandbox
      socat
      bubblewrap

      lsof

      jujutsu
    ] ++ lib.optionals cfg.emacsTools.enable [
      pkgs.${namespace}.emacs-lsp-proxy
    ] ++ lib.optionals cfg.tools.dev.enable [
      conda
      pkgs-unstable.mise
      devenv
      devpod
      devbox
      mprocs
    ] ++ lib.optionals cfg.tools.ai.enable [
      ollama-rocm
      # for aider
      python312Packages.playwright
      pkgs-unstable.tdlib
      #pkgs.${namespace}.aider
      pkgs.aider-chat
      #pkgs-unstable.aider-chat
      #pkgs-unstable.claude-code
      pkgs.${namespace}.zli
    ] ++ lib.optionals (cfg.tools.ai.enable && cfg.tools.ai.llmAgents.enable) [
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
      (lib.hiPrio pkgs-nix-ai.agent-browser)
      #pkgs-nix-ai.coding-agent-search
      pkgs-nix-ai.gemini-cli
      #pkgs-nix-ai.claude-code-acp
      pkgs-nix-ai.openspec
      pkgs-nix-ai.cc-switch-cli
      #pkgs.${namespace}.trojan-go
      pkgs-nix-ai.eca
    ] ++ lib.optionals cfg.tools.network.enable [
      pkgs-unstable.tailscale
      sshuttle
    ] ++ lib.optionals cfg.tools.database.enable [
      mysql84
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
      feishu
      vscode
      code-cursor
      wireshark-qt
      pkgs-unstable.localsend
      sioyek
      pkgs-unstable.zed-editor
      libnotify
    ] ++ lib.optionals cfg.tools.database.enable [
      redisinsight
      mongodb-compass
      pkgs-unstable.dbeaver-bin
    ] ++ lib.optionals cfg.tools.office.enable [
      libreoffice
      pkgs-unstable.wpsoffice
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
