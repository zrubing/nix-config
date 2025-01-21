{ pkgs, inputs , system, ... }:
let
  pkgs-unstable =  inputs.nixpkgs-unstable.legacyPackages.${system};
in {
  config =
    {
      home.packages = with pkgs; [
        localsend
      ];

    };
}
