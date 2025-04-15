{
  config,
  lib,
  pkgs,
  namespace,
  inputs,
  ...
}:
with lib;
with lib.${namespace};
let
  hm = config.lib;
  cfg = config.${namespace}.rgbar;
in
{
  options.${namespace}.rgbar = with types; {
    enable = mkBoolOpt false "Enable rgbar";
  };

  config = mkIf cfg.enable {
    systemd.user.services.rgbar = {
      Unit = {
        Description = "rgbar for niri Wayland";
        BindsTo = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        Requisite = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        ExecStart = "${pkgs.${namespace}.rgbar}/bin/rgbar";
        StandardOutput = "journal";
      };
    };

  };
}
