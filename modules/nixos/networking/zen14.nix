{
  config,
  inputs,
  lib,
  ...
}:
let
  hostsSecretKey = "networking/extra_hosts/zen14";
in
{
  config = lib.mkIf (config.networking.hostName == "zen14") {
    sops.secrets.${hostsSecretKey} = {
      sopsFile = "${inputs.mysecrets}/secrets/env.yaml";
    };

    networking.extraHosts = ''
      ${config.sops.placeholder.${hostsSecretKey}}
    '';
  };
}
