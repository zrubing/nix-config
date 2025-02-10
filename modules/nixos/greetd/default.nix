{ config, lib, namespace, pkgs, ... }:
let
  cfg = config.${namespace}.greetd;

  desktopsDir = config.services.displayManager.sessionData.desktops;
  desktopSessions =
    lib.concatMapStringsSep ":" (dir: "${desktopsDir}/share/${dir}") [
      "wayland-sessions"
      "xsessions"
    ];
in {
  options.${namespace}.greetd = with lib; {
    enable = mkEnableOption "Use Wayland desktop";
  };

  config = lib.mkIf cfg.enable {
    # home.${namespace}.linux.desktop.displayServer = "wayland";

    services.greetd = {
      enable = true;
      vt = 1; # TODO maybe change to another VT
      settings = {
        default_session = {
          user = "${config.${namespace}.user.name}";
          command =
            "${pkgs.greetd.tuigreet}/bin/tuigreet --time --sessions ${desktopSessions}";
        };
      };
    };

    # Allow swaylock to unlock the screen
    security.pam.services.swaylock = { };
  };
}
