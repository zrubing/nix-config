{
  description = "A template that shows all standard flake outputs";

  inputs = {
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    agenix.url = "github:ryantm/agenix";

    home-manager.url = "github:nix-community/home-manager/release-25.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

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
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils-plus.follows = "flake-utils-plus";
        flake-compat.follows = "flake-compat";
      };
    };
    niri.url = "github:sodiboo/niri-flake";

    tree-sitter-grammars.url = "github:marsam/tree-sitter-grammars";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rime-3gram = {
      url = "https://github.com/amzxyz/RIME-LMDG/releases/download/v2n3/amz-v2n3m1-zh-hans.gram";
      flake = false;
    };

    subagents = {
      url = "git+ssh://git@github.com/wshobson/agents?ref=main";
      flake = false;
    };

    subagents2 = {
      url = "git+ssh://git@github.com/VoltAgent/awesome-claude-code-subagents";
      flake = false;
    };

    codex-nix.url = "github:sadjow/codex-nix";

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
    # specialArgs = {
    #   pkgs-unstable = import inputs.nixpkgs-unstable {
    #     # To use chrome, we need to allow the installation of non-free software
    #     config.allowUnfree = true;
    #   };
    # };
    lib.mkFlake {

      # Add modules to all NixOS systems.
      systems.modules.nixos = with inputs; [
        agenix.nixosModules.default
        niri.nixosModules.niri
      ];

      systems.modules.darwin = with inputs; [ ];

      homes.modules = with inputs; [
        agenix.homeManagerModules.default
        sops-nix.homeManagerModules.sops
      ];

      # The attribute set specified here will be passed directly to NixPkgs when
      # instantiating the package set.
      channels-config = {
        # Allow unfree packages.
        allowUnfree = true;

      };

    };

}
