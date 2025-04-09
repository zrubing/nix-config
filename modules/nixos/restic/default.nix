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
      org-roam-dir = {
        paths = [ "/home/jojo/org-roam-dir" ];
        repository = "rclone:ali:org-roam-backup/";
        initialize = true;
        rcloneConfigFile = "/run/agenix/rclone.conf";
        passwordFile = "/run/agenix/restic-password";
      };
    };
  };

}
