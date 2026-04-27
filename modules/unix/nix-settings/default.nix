{ inputs, lib, ... }:
{
  nix = {
    extraOptions = ''
      trusted-users = root jojo

      extra-substituters = https://devenv.cachix.org https://attic.xuyh0120.win/lantian https://cache.garnix.io
      extra-trusted-public-keys = devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw= lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc= cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=
    '';
    # TODO try this?
    # enable = config.host.role != "cloud-server";

    # Disable channels
    channel.enable = false;

    # Pin <nixpkgs> for nix-shell and so on
    nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];

    # Pin nixpkgs in the registry to this flake's version
    registry.nixpkgs.flake = inputs.nixpkgs;

    # From flake-utils-plus
    # TODO enable and delete the line above
    # generateRegistryFromInputs = true;

    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      log-lines = 50;
      use-xdg-base-directories = true;
      warn-dirty = false;
      trusted-users = [
        "@wheel"
        "jojo"
      ]; # TODO revise this?

      allow-import-from-derivation = true;
      accept-flake-config = true;
      substituters = [
        "https://nix-community.cachix.org"
        "https://niri.cachix.org"

        "https://numtide.cachix.org"
        "https://attic.xuyh0120.win/lantian"
        "https://cache.garnix.io"
      ];

      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
        "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
        "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
        "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      ];
    };

    gc = {
      automatic = lib.mkDefault false;
      options = "--delete-older-than 1d";
    };
  };
}
