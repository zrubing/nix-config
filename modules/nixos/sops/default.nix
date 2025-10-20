{
  inputs,
  config,
  ...
}:
let
  mysecrets = inputs.mysecrets;
in
{

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  sops.secrets."easytier/ali/network_secret" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
  };
  sops.secrets."easytier/ali/network_name" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
  };

  sops.templates."easytier-config".content = ''
    instance_name = "zen14"

    [network_identity]
    network_name = "file://${config.sops.secrets."easytier/ali/network_name".path}"
    network_secret = "file://${config.sops.secrets."easytier/ali/network_secret".path}"
  '';

}
