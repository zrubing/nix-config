{
  description = "A template that shows all standard flake outputs";

  inputs = {
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    agenix.url = "github:ryantm/agenix";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    claude-code.url = "github:sadjow/claude-code-nix";

    llm-agents.url = "github:numtide/llm-agents.nix";

    pi-guardrails-src = {
      url = "github:zrubing/pi-guardrails?rev=712a2ae0b5150a867414bfcb99049128339dc44a";
      flake = false;
    };

    catppuccin-bat = {
      url = "github:catppuccin/bat";
      flake = false;
    };

    # Emacs Overlays
    emacs-overlay = {
      url = "github:nix-community/emacs-overlay";
    };

    # doom-emacs is a configuration framework for GNU Emacs.
    doomemacs = {
      url = "github:doomemacs/doomemacs";
      flake = false;
    };

    flake-utils.url = "github:numtide/flake-utils";

    flake-utils-plus = {
      url = "github:gytis-ivaskevicius/flake-utils-plus";
      inputs.flake-utils.follows = "flake-utils";
    };

    flake-compat.url = "github:edolstra/flake-compat";

    # The name "snowfall-lib" is required due to how Snowfall Lib processes your
    # flake's inputs.
    snowfall-lib = {
      url = "github:snowfallorg/lib";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    niri.url = "github:sodiboo/niri-flake";

    tree-sitter-grammars.url = "github:marsam/tree-sitter-grammars";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fast-nix-gc = {
      url = "github:Mic92/fast-nix-gc";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    k0s-nix.url = "github:zrubing/k0s-nix/main";

    rime-3gram = {
      url = "https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram";
      flake = false;
    };

    # subagents = {
    #   url = "git+ssh://git@github.com/wshobson/agents?ref=main";
    #   flake = false;
    # };

    # subagents2 = {
    #   url = "git+ssh://git@github.com/VoltAgent/awesome-claude-code-subagents";
    #   flake = false;
    # };

    # noctalia-qs-patched = {
    #   url = "path:./third_party/noctalia-qs-patched";
    #   inputs.nixpkgs.follows = "nixpkgs-unstable";
    # };

    # noctalia = {
    #   url = "github:noctalia-dev/noctalia-shell";
    #   inputs.nixpkgs.follows = "nixpkgs-unstable";
    #   inputs.noctalia-qs.follows = "noctalia-qs-patched";
    # };
    #
    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    gpui-shell = {
      url = "github:zrubing/gpui-shell";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    antigravity-nix = {
      url = "github:jacopone/antigravity-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    design-doc-mermaid = {
      url = "github:SpillwaveSolutions/design-doc-mermaid?rev=e13f987306d5cd7a34f541927a3228343dd90e45";
      flake = false;
    };

    caveman-skills = {
      url = "github:JuliusBrussee/caveman?rev=84cc3c14fa1e10182adaced856e003406ccd250d";
      flake = false;
    };

    anysearch-skill = {
      url = "github:anysearch-ai/anysearch-skill?rev=db3d76e5597aec7261257be5322dd211c9d9bb87";
      flake = false;
    };

    superpowers = {
      url = "github:obra/superpowers?rev=6fd4507659784c351abbd2bc264c7162cfd386dc";
      flake = false;
    };

    process-compose = {
      url = "github:F1bonacc1/process-compose";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    ########################  My own repositories  #########################################
    # my private secrets, it's a private repository, you need to replace it with your own.
    # use ssh protocol to authenticate via ssh-agent/ssh-key, and shallow clone to save time
    mysecrets = {
      url = "git+ssh://git@github.com/zrubing/nix-secrets.git?ref=main";
      flake = false;
    };

  };
  outputs =
    inputs:
    let
      lib = inputs.snowfall-lib.mkLib {
        inherit inputs;
        src = ./.;
      };
    in
    let
      permittedInsecureList = [
        "electron-38.8.4"
        "nodejs-slim-20.20.2"
        "nodejs-20.20.2"
        "pnpm-10.29.2"
      ];
    in
    let
      snowfall = lib.mkFlake {

        # Add modules to all NixOS systems.
        systems.modules.nixos = with inputs; [
          agenix.nixosModules.default
          sops-nix.nixosModules.sops
          fast-nix-gc.nixosModules.default
          k0s-nix.nixosModules.default
        ];

        systems.modules.darwin = with inputs; [ ];

        homes.modules = with inputs; [
          noctalia.homeModules.default
          niri.homeModules.niri
          #niri.nixosModules.niri
          agenix.homeManagerModules.default
          sops-nix.homeManagerModules.sops
        ];

        # 顶级 overlays：snowfall 把它喂给 channels.nixpkgs.overlaysBuilder，
        # 应用到默认 nixpkgs channel。
        overlays = [
          inputs.k0s-nix.overlays.default
          inputs.process-compose.overlays.default
          # 复用 snowfall 已构造好的 nixpkgs-unstable channel（其 allowUnfree /
          # permittedInsecurePackages 已由下方 channels-config 自动应用），
          # 注入为 pkgs.unstable，模块内可直接 pkgs.unstable.<pkg>。
          (final: _prev: {
            unstable = inputs.self.pkgs.${final.stdenv.hostPlatform.system}.nixpkgs-unstable;
          })
        ];

        # channels-config 只用于设置 nixpkgs 的 config（allowUnfree /
        # permittedInsecurePackages），会被 flake-utils-plus 应用到 nixpkgs 与
        # nixpkgs-unstable 两个 channel。不要在此放 overlays：flake-utils-plus
        # 的 channelsConfig 只接受 config 键，overlays 会被静默忽略。
        channels-config = {
          # Allow unfree packages.
          allowUnfree = true;
          doCheckByDefault = false;
          permittedInsecurePackages = permittedInsecureList;
        };

      };
    in
    snowfall
    // {
      devShells.x86_64-linux.trading =
        let
          pkgs = import inputs.nixpkgs {
            system = "x86_64-linux";
            config.allowUnfree = true;
          };
        in
        pkgs.mkShell {
          packages = [
            (pkgs.python312.withPackages (ps: [
              snowfall.packages.x86_64-linux.tradingagents
            ]))
          ];
          shellHook = ''
            if [ -f .env ]; then
              echo "[trading] loading .env from $(pwd)"
              set -a && source .env && set +a
            elif [ -f "$HOME/.config/tradingagents/.env" ]; then
              echo "[trading] loading sops template"
              set -a && source "$HOME/.config/tradingagents/.env" && set +a
            else
              echo "[trading] no .env or template found, skipping"
            fi
          '';
        };
    };

}
