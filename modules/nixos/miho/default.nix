{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  mysecrets = inputs.mysecrets;
in
{

  environment.systemPackages = with pkgs; [ mihomo ];

  age.secrets.miho-conf.file = "${mysecrets}/miho-conf.age";
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  services.mihomo = {
    enable = true;
    configFile = "/run/agenix/miho-conf";
    tunMode = true;
  };
}
