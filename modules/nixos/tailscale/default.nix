{
  lib,
  inputs,
  system,
  config,
  ...
}:
let
  mysecrets = inputs.mysecrets;
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};

in
{

  #age.secrets.tailscale-authkey.file = "${mysecrets}/tailscale-authkey.age";
  age.secrets.headscale-authkey.file = "${mysecrets}/headscale-authkey.age";
  services.tailscale = {
    enable = true;
    extraUpFlags = [
      "--login-server=https://127.0.0.1:2001"
      "--accept-dns=true"
      "--dns=on"
      "--dns-suffix=tailnet.local"
    ];
    authKeyFile = config.age.secrets.headscale-authkey.path;
    package = pkgs-unstable.tailscale;

  };

}
