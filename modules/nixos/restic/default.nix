{
  pkgs,
  config,
  lib,
  namespace,
  ...
}:
with lib;
with lib.${namespace};
let
  cfg = config.${namespace}.restic;
  homedir = "/home/jojo";
  rcloneConfigFile = "/run/agenix/rclone.conf";
  passwordFile = "/run/agenix/restic-password";
in
{
  options.${namespace}.restic = with types; {
    enable = mkBoolOpt false "Enable restic backup support";
  };

  config = mkIf cfg.enable {

    environment.systemPackages = with pkgs; [
      rclone
      restic
    ];

    services.restic.backups = {
      password-store = {
        paths = [ "${homedir}/.local/share/password-store" ];
        repository = "rclone:ali:password-store/";
        initialize = true;
        inherit rcloneConfigFile passwordFile;
      };
      org-roam-dir = {
        paths = [ "${homedir}/org-roam-dir" ];
        repository = "rclone:ali:org-roam-backup/";
        initialize = true;
        inherit rcloneConfigFile passwordFile;
      };
    };
  };

}
