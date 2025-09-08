{
  config,
  pkgs,
  inputs,
  system,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) system; # for agenix pkg
  username = config.snowfallorg.user.name;
  mysecrets = inputs.mysecrets;
  mystuff = pkgs.writeShellScriptBin "echo-secret" ''
    ${pkgs.coreutils}/bin/cat ${config.age.secrets.authinfo.path} > /home/${username}/.authinfo
    ${pkgs.coreutils}/bin/mkdir -p /home/${username}/.config/rclone
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."rclone.conf".path} > /home/${username}/.config/rclone/rclone.conf
    ${pkgs.coreutils}/bin/mkdir -p /home/${username}/.config/topsap
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."topsap/env.ini".path} > /home/${username}/.config/topsap/env.ini

    ${pkgs.coreutils}/bin/cat ${config.age.secrets.netrc.path} > /home/${username}/.netrc

    ${pkgs.coreutils}/bin/mkdir -p /home/${username}/.kube
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."work/k8s/milvzn.kube".path} > /home/${username}/.kube/config

    ${pkgs.coreutils}/bin/mkdir -p /home/${username}/.claude
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."claude.settings.json".path} > /home/${username}/.claude/settings.json

  '';
in
{

  config = {

    age.identityPaths = [ "/home/${username}/.ssh/id_ed25519" ];
    age.secrets.authinfo.file = "${mysecrets}/authinfo.age";
    age.secrets."rclone.conf".file = "${mysecrets}/rclone.conf.age";
    age.secrets."topsap/env.ini".file = "${mysecrets}/topsap/env.ini.age";
    age.secrets."ssh/topsap-config".file = "${mysecrets}/ssh/topsap-config.age";
    age.secrets."ssh/work-config".file = "${mysecrets}/ssh/work-config.age";
    age.secrets."ssh/default-config".file = "${mysecrets}/ssh/default-config.age";

    age.secrets.netrc.file = "${mysecrets}/netrc.age";
    age.secrets."work/k8s/milvzn.kube".file = "${mysecrets}/work/k8s/milvzn.kube.age";

    age.secrets."claude.settings.json".file = "${mysecrets}/claude.settings.json.age";

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
