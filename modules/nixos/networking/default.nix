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

    networking.extraHosts = ''
      127.0.0.1 cc-proxy-work-volcengine-kimi.local
      127.0.0.1 cc-proxy-work-volcengine-deepseek.local
      127.0.0.1 cc-proxy-self-zhipu-glm.local
      172.16.6.101 docker.pve.com
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
