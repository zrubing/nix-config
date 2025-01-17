{
  description = "A template that shows all standard flake outputs";

  inputs = {
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

  };

  outputs = { self, nixpkgs, home-manager, agenix, ... }@inputs: {
    nixosConfigurations.nixos = let
      username = "jojo";
      specialArgs = { inherit username inputs; };
    in nixpkgs.lib.nixosSystem {
      inherit specialArgs;
      system = "x86_64-linux";

      modules = [
        ./hosts/nixos
        ./users/${username}/nixos.nix
        agenix.nixosModules.default

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;

          home-manager.extraSpecialArgs = inputs // specialArgs;
          home-manager.users.${username} = import ./users/${username}/home.nix;
        }
      ];
    };

  };
}
