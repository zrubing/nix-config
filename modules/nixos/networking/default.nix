{
  config,
  inputs,
  lib,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.networking;
  mysecrets = inputs.mysecrets;
  hostName = config.networking.hostName;
  hostsSecretKey = "networking/extra_hosts/${hostName}";
in
{
  options.${namespace}.networking = with lib; {
    wifi.enable = mkEnableOption "Enable wifi";
  };

  config = {

    networking.firewall.enable = false;

    assertions = [
      {
        assertion = hostName != null;
        message = "networking.hostName must be set to load host-specific hosts entries from sops.";
      }
    ];

    sops.secrets.${hostsSecretKey} = {
      sopsFile = "${mysecrets}/secrets/env.yaml";
    };

    networking.extraHosts = ''
      ${config.sops.placeholder.${hostsSecretKey}}
    '';

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

    # 启用 systemd-resolved
    services.resolved = {
      enable = true;
      dnssec = "false";
      extraConfig = ''
        [Resolve]
        DNS=127.0.0.1
        FallbackDNS=8.8.8.8
      '';
    };

    # 1. NM 只管连接，不管 DNS
    networking.networkmanager.enable = true;
    networking.networkmanager.dns = lib.mkForce "none";
    networking.dhcpcd.enable = false;

    # 2. 系统 DNS 指向 systemd-resolved
    networking.nameservers = [ "127.0.0.1" ];

    # 3. wlp1s0 继续 DHCP 拿地址，但 DNS 不走 DHCP
    networking.useDHCP = false;
    networking.interfaces.wlp1s0.useDHCP = true;
  };
}
