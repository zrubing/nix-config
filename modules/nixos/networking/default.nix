{
  config,
  lib,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.networking;
in
{
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

    # networking.nameservers = [
    #   "1.1.1.1"
    #   "1.0.0.1"
    # ];
    services.resolved = {
      enable = false;
      extraConfig = ''
        [Resolve]
        DNS=127.0.0.1:1053
        DNSOverTLS=no
        DNSSEC=no
      '';
    };

    # services.dnsmasq = {
    #   enable = false;

    #   settings = {

    #     address = [
    #       "/john-server.ts.net/100.64.0.2"
    #     ];
    #     server = [
    #       "100.100.100.100" # for headscale
    #       "1.1.1.1"
    #       "1.0.0.1"
    #       "2606:4700:4700::1111"
    #       "2606:4700:4700::1001"
    #     ];
    #   };

    # };

    networking = {
      #firewall.enable = true;

      nameservers = [
        #"100.100.100.100" # for headscale
        "127.0.0.1"
        "1.1.1.1"
        "1.0.0.1"
        "2606:4700:4700::1111"
        "2606:4700:4700::1001"
      ];

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
