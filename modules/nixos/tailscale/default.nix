{
  lib,
  inputs,
  system,
  ...
}:
let
  mysecrets = inputs.mysecrets;
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
in
{

  age.secrets.tailscale-authkey.file = "${mysecrets}/tailscale-authkey.age";
  services.tailscale = {
    enable = true;
    authKeyFile = "/run/agenix/tailscale-authkey";
    package = pkgs-unstable.tailscale;

  };

}
