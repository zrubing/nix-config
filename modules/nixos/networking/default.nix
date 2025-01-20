{ config, lib, namespace, ... }:
let cfg = config.${namespace}.networking;
in {
  options.${namespace}.networking = with lib; {
    wifi.enable = mkEnableOption "Enable wifi";
  };

  config = {

    networking.firewall.enable = false;

    # Enable the OpenSSH daemon.
    services.openssh = {
      enable = true;
      settings = {
        X11Forwarding = true;
        PermitRootLogin = "no"; # disable root login
        # PasswordAuthentication = false; # disable password login
      };
      openFirewall = true;
    };

    networking = {
      #firewall.enable = true;

      nameservers =
        [ "1.1.1.1" "1.0.0.1" "2606:4700:4700::1111" "2606:4700:4700::1001" ];

      useDHCP = lib.mkDefault cfg.wifi.enable;
      # TODO maybe we should add a "main interface" thingy in config.host
      # interfaces.ens3.useDHCP = true;

      wireless.enable = !config.networking.networkmanager.enable;

      networkmanager = {
        enable = lib.mkDefault cfg.wifi.enable;
        insertNameservers = config.networking.nameservers;

        # TODO: try to enable someday
        # wifi.backend = "iwd";
      };
    };
  };
}
