{ inputs, lib, ... }: {
  nix = {
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
      experimental-features = [ "nix-command" "flakes" ];
      log-lines = 50;
      use-xdg-base-directories = true;
      warn-dirty = false;
      trusted-users = [ "@wheel" ]; # TODO revise this?

      allow-import-from-derivation = true;
    };

    gc = {
      automatic = lib.mkDefault false;
      options = "--delete-older-than 1d";
    };
  };
}
