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

    # networking.nameservers = [
    #   "1.1.1.1"
    #   "1.0.0.1"
    # ];
    services.resolved = {
      enable = true;
      extraConfig = ''
        [Resolve]
        DNS=127.0.0.1:1053
        DNSOverTLS=no
        DNSSEC=no
      '';
    };

    services.dnsmasq = {
      enable = false;

      settings = {
        # 忽略系统 resolv.conf，避免循环（保持原样）
        resolv-file = "/etc/resolv.dnsmasq.conf"; # 确保这个文件存在且为空或正确配置

        # 启用本地查询解析，处理 localhost 等
        #resolveLocalQueries = true;

        # 添加缓存，减少重复查询延迟（原为 0，可能导致慢）
        cache-size = 1000;

        # 上游服务器（保持原样，但如果 1053 是本地服务，确保无循环）
        server = [
          "127.0.0.1#1053"
          "/.et.net/100.100.100.101"
          "/.lan/127.0.0.1#1053"
        ];

        # 监听 Podman 接口和 loopback（lo），以服务主机和容器
        interface = [
          "lo"
        ];

        # 监听地址：添加 IPv4 和 IPv6 localhost，支持双栈
        listen-address = "127.0.0.1,::1";

        # 绑定到指定接口，避免监听所有，增强安全
        bind-interfaces = true;

        # 可选：强制上游服务器顺序（如果需要优先本地）
        strict-order = true;
      };
    };

    networking = {
      #firewall.enable = true;

      nameservers = [
        #"100.100.100.100" # for headscale
        "127.0.0.1"
        # "1.1.1.1"
        # "1.0.0.1"
        # "2606:4700:4700::1111"
        # "2606:4700:4700::1001"
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
