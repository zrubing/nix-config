{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  system,
  ...
}:
let
  mysecrets = inputs.mysecrets;
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  cfg = config.${namespace}.miho;
in
{

  options.${namespace}.miho = with lib; {
    enable = mkEnableOption "Enable mihomo";
  };

  config = lib.mkIf cfg.enable {

    environment.systemPackages = with pkgs; [ pkgs-unstable.mihomo ];

    age.secrets.miho-conf.file = "${mysecrets}/miho-conf.age";
    age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    services.mihomo = {
      enable = true;
      package = pkgs-unstable.mihomo;
      configFile = "/run/agenix/miho-conf";
      tunMode = true;
    };
  };

}
