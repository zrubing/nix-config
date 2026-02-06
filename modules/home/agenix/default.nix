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
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = system;
    config.allowUnfree = true;
  };
  mystuff = pkgs.writeShellScriptBin "echo-secret" ''
    ${pkgs.coreutils}/bin/cat ${config.age.secrets.authinfo.path} > /home/${username}/.authinfo
    ${pkgs.coreutils}/bin/chmod 0600 /home/${username}/.authinfo
    ${pkgs.coreutils}/bin/mkdir -p /home/${username}/.config/rclone
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."rclone.conf".path} > /home/${username}/.config/rclone/rclone.conf
    ${pkgs.coreutils}/bin/mkdir -p /home/${username}/.config/topsap
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."topsap/env.ini".path} > /home/${username}/.config/topsap/env.ini

    ${pkgs.coreutils}/bin/cat ${config.age.secrets.netrc.path} > /home/${username}/.netrc

    ${pkgs.coreutils}/bin/mkdir -p /home/${username}/.kube

    ${pkgs.coreutils}/bin/cat ${config.age.secrets."work/k8s/milvzn.kube".path} > /home/${username}/.kube/config-milv-default.yml
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."work/k8s/sinopec.milv.kube".path} > /home/${username}/.kube/config-milv-sinopec.yml
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."work/k8s/k0s.kube".path} > /home/${username}/.kube/config-k0s.yml


    ${pkgs.coreutils}/bin/mkdir -p /home/${username}/.codex
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."codex/config.toml".path} > /home/${username}/.codex/config.toml
    ${pkgs.coreutils}/bin/cat ${config.age.secrets."codex/auth.json".path} > /home/${username}/.codex/auth.json

    ${pkgs.coreutils}/bin/cat ${config.age.secrets."ccr.config.json".path} > /home/${username}/.claude-code-router/config.json
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
    age.secrets."work/k8s/sinopec.milv.kube".file = "${mysecrets}/work/k8s/milvzn.sinopec.kube.age";
    age.secrets."work/k8s/k0s.kube".file = "${mysecrets}/work/k8s/k0s.kube.age";

    age.secrets."claude.settings.json".file = "${mysecrets}/claude.settings.json.age";

    age.secrets."codex/config.toml".file = "${mysecrets}/codex/config.toml.age";
    age.secrets."codex/auth.json".file = "${mysecrets}/codex/auth.json.age";

    age.secrets."ccr.config.json".file = "${mysecrets}/ccr.config.age";

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
