{ inputs, lib, ... }:
{
  nix = {
    extraOptions = ''
        trusted-users = root jojo

        extra-substituters = https://devenv.cachix.org
        extra-trusted-public-keys = devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=
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
      trusted-users = [ "@wheel" "jojo" ]; # TODO revise this?

      allow-import-from-derivation = true;
      substituters = [
        "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
        "https://mirrors.nju.edu.cn/nix-channels/store"
        "https://nix-community.cachix.org"
      ];

      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };

    gc = {
      automatic = lib.mkDefault false;
      options = "--delete-older-than 1d";
    };
  };
}
