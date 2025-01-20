{ config, lib, pkgs, ... }:
let cfg = config.services.swaybg;
in {
  options.services.swaybg = with lib; {
    enable = mkEnableOption "Run swaybg on graphical-session startup";

    wallpaper = mkOption {
      type = types.str;
      default = "Pictures/Wallpapers/desktop";
      description = "Images to use";
    };

    mode = mkOption {
      type = types.enum [ "stretch" "fit" "fill" "center" "tile" ];
      default = "fill";
      description = "Mode to use for the image";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.swaybg = {
      Unit = {
        Description = "Wallpaper daemon for Wayland";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        ExecStart =
          "${pkgs.swaybg}/bin/swaybg --image ${cfg.wallpaper} --mode ${cfg.mode}";
      };
    };
  };
}
