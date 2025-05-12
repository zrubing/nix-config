{
  lib,
  inputs,
  system,
  config,
  namespace,
  ...
}:
let
  mysecrets = inputs.mysecrets;
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};

  cfg = config.${namespace}.tailscale;
in
{
  options.${namespace}.tailscale = {
    headscaleAuthkeyFile = lib.mkOption {
      type = lib.types.str;
      default = "headscale-authkey.age";
      description = "Name of the age-encrypted headscale authkey file";
    };
  };

  config = {
    #age.secrets.tailscale-authkey.file = "${mysecrets}/tailscale-authkey.age";
    age.secrets.headscale-authkey.file = "${mysecrets}/${cfg.headscaleAuthkeyFile}";
    services.tailscale = {
      enable = false;
      extraUpFlags = [
        "--login-server=http://127.0.0.1:2001"
        "--accept-dns=true"
      ];
      authKeyFile = config.age.secrets.headscale-authkey.path;
      package = pkgs-unstable.tailscale;

    };
  };

}
