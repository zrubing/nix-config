{ config, lib, namespace, pkgs, ... }:
let cfg = config.${namespace}.desktop;
in {
  options.${namespace}.desktop = with lib; {
    enable = mkEnableOption "Desktop role";
    autoLogin = mkEnableOption "Autologin";
  };

  config = lib.mkIf cfg.enable {
    ${namespace} = {
      audio.enable = true;
      fonts.enable = true;
      #gaming.steam.enable = lib.mkDefault true;
      host.ssh.allowRootLogin = false;
    };

    home.${namespace}.linux.desktop.enable = true;

    services.tailscale.enable = true;

    virtualisation.docker.enable = lib.mkDefault true;

    security.polkit.enable = true;

    # Allow mounting NTFS drives.
    boot.supportedFilesystems = [ "ntfs" ];

    # Make the power key suspend instead of turning off the computer.
    services.logind.extraConfig = "HandlePowerKey=suspend";

    # Activate blueman if bluetooth is enabled.
    # Gnome already has a bluetooth thingy so we don't need it there.
    services.blueman.enable = config.hardware.bluetooth.enable
      && !config.services.xserver.desktopManager.gnome.enable;

    services.locate = {
      enable = true;
      package = pkgs.plocate;
      interval = "hourly";
      localuser = null;
    };

    #programs.nix-index.enable = true;

    # This section is dedicated to attempting to make gsettings work.
    # I honestly don't know whether it does anything.
    environment.systemPackages = with pkgs; [
      # Probably to get gsettings to work.
      glib
      xdg-utils

      adwaita-icon-theme

      # For lsusb
      usbutils

      # For readelf
      binutils
    ];

    programs.dconf.enable = true;

    # Enable stuff like file picker in some applications
    xdg.portal = {
      enable = true;
      config.common.default = "*";
      extraPortals =
        lib.optionals (!config.services.xserver.desktopManager.gnome.enable) [
          pkgs.xdg-desktop-portal-gtk
          pkgs.xdg-desktop-portal-gnome
        ];
    };

    # Use the Gnome theme in Qt applications
    qt = {
      enable = true;
      platformTheme = lib.mkDefault "gnome";
      style = lib.mkDefault "adwaita-dark";
    };

    # https://github.com/NixOS/nixpkgs/issues/180175
    systemd.services.NetworkManager-wait-online = {
      serviceConfig = {
        ExecStart = [ "" "${pkgs.networkmanager}/bin/nm-online -q" ];
      };
    };
  };
}
