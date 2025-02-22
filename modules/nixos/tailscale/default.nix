{ lib, inputs, ... }:
let
  mysecrets = inputs.mysecrets;
in
{

  age.secrets.tailscale-authkey.file = "${mysecrets}/tailscale-authkey.age";
  services.tailscale = {
    enable = true;
    authKeyFile = "/run/agenix/tailscale-authkey";

  };

}
