{
  description = "Patched noctalia-qs for nix-config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default-linux";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, systems, treefmt-nix, ... }:
    let
      eachSystem = fn: nixpkgs.lib.genAttrs (import systems) (system: fn nixpkgs.legacyPackages.${system});

      mkDate =
        longDate:
        nixpkgs.lib.concatStringsSep "-" [
          (builtins.substring 0 4 longDate)
          (builtins.substring 4 2 longDate)
          (builtins.substring 6 2 longDate)
        ];

      version = mkDate (self.lastModifiedDate or "19700101") + "_" + (self.shortRev or "dirty");
      gitRev = self.rev or self.dirtyRev or "dirty";
      treefmtEval = eachSystem (pkgs: treefmt-nix.lib.evalModule pkgs ./treefmt.nix);
    in
    {
      overlays.default = final: _prev: {
        quickshell = final.callPackage ./package.nix {
          inherit version gitRev;
        };
      };

      packages = eachSystem (pkgs: {
        quickshell = pkgs.callPackage ./package.nix {
          inherit version gitRev;
        };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.quickshell;
      });

      devShells = eachSystem (_pkgs: { });

      formatter = eachSystem (pkgs: treefmtEval.${pkgs.system}.config.build.wrapper);
    };
}
