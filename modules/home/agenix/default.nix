{ config, pkgs, inputs , system, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) system; # for agenix pkg
  mystuff = pkgs.writeShellScriptBin "echo-secret" ''
    ${pkgs.coreutils}/bin/cat ${config.age.secrets.authinfo.path} > /home/jojo/.authinfo
  '';
in
{

  config = {


    age.identityPaths = [ "/home/${config.snowfallorg.user.name}/.ssh/id_ed25519" ];
    age.secrets.authinfo.file = ../../../secrets/authinfo.age;

    home.packages = [
      #inputs.agenix.packages.${system}.agenix
      mystuff # so now in the terminal running `echo-secret` runs the above command
    ];

    systemd.user.services."agenix-echo-secret" = {
      Unit = {
        Description = "agenix in home";
        After = [ "agenix.service" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${mystuff}/bin/echo-secret";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };

}
