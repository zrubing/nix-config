{
  description = "A template that shows all standard flake outputs";

  inputs = { nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11"; };
  outputs = { self, nixpkgs, ... }@inputs: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./configuration.nix ];
    };
  };
}
