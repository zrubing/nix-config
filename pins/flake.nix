{
  description = "Shared nixpkgs pins for zrubing/nix-config consumers";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = inputs: {
    inherit (inputs) nixpkgs nixpkgs-unstable;
  };
}
