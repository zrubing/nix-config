{
  description = "A template that shows all standard flake outputs";

  inputs = {
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    agenix.url = "github:ryantm/agenix";

    home-manager.url = "github:nix-community/home-manager/release-24.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    catppuccin-bat = {
      url = "github:catppuccin/bat";
      flake = false;
    };

    # Emacs Overlays
    emacs-overlay = { url = "github:nix-community/emacs-overlay"; };

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

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  # outputs =
  #   inputs:
  #   let
  #     secrets = { lib, ... }: {
  #       age.secrets = with lib;
  #         listToAttrs (map
  #           (name: {
  #             name = removeSuffix ".age" name;
  #             value = {
  #               file = (snowfall.fs.get-file "secrets/${name}");
  #             };
  #           })
  #           (attrNames (import (snowfall.fs.get-file "secrets/secrets.nix"))));
  #     };
  #   in
  #   (inputs.snowfall-lib.mkFlake {
  #     inherit inputs;
  #     src = ./.;

  #     channels-config = {
  #       allowUnfree = true;
  #     };

  #     systems.modules.nixos = with inputs; [
  #       agenix.darwinModules.default
  #       secrets
  #     ];

  #   });

  outputs = inputs:
    let
      lib = inputs.snowfall-lib.mkLib {
        inherit inputs;
        src = ./.;
      };
      # specialArgs = {
      #   pkgs-unstable = import inputs.nixpkgs-unstable {
      #     # To use chrome, we need to allow the installation of non-free software
      #     config.allowUnfree = true;
      #   };
      # };
    in lib.mkFlake {

      # homes.users.jojo.specialArgs = specialArgs;
      # systems.hosts.nova13.specialArgs = specialArgs;

      # Add modules to all NixOS systems.
      systems.modules.nixos = with inputs; [ agenix.nixosModules.default ];

      systems.modules.darwin = with inputs; [ ];

      # homes.modules = with inputs; [
      # ];

    };

  # outputs = { self, nixpkgs, home-manager, agenix, ... }@inputs: {
  #   nixosConfigurations.nixos = let
  #     username = "jojo";
  #     system = "x86_64-linux";

  #     # use unstable branch for some packages to get the latest updates
  #     pkgs-unstable = import inputs.nixpkgs-unstable {
  #       inherit system; # refer the `system` parameter form outer scope recursively
  #       # To use chrome, we need to allow the installation of non-free software
  #       config.allowUnfree = true;
  #     };

  #     specialArgs = { inherit username inputs pkgs-unstable; };
  #   in nixpkgs.lib.nixosSystem {
  #     inherit specialArgs system;

  #     modules = [
  #       {
  #         modules.desktop.wayland.enable = true;
  #       }
  #       ./hosts/nixos
  #       ./users/${username}/nixos.nix
  #       agenix.nixosModules.default

  #       home-manager.nixosModules.home-manager
  #       {
  #         home-manager.useGlobalPkgs = true;
  #         home-manager.useUserPackages = true;

  #         home-manager.extraSpecialArgs = inputs // specialArgs;
  #         home-manager.users.${username} = import ./users/${username}/home.nix;
  #       }
  #     ];
  #   };

  # }
}
