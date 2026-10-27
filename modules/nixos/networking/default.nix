{
  config,
  lib,
  namespace,
  pkgs,
  ...
}:
{
  imports = [
    ./zen14.nix
    ./nova13.nix
  ];

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

    # 启用 systemd-resolved。
    #
    # 上游 DNS 分两层，由代理模块的 tun 决定用哪一层：
    #   · 代理在跑：tun 带 `~.` routing domain，所有查询走 tun（实测 wlp1s0 上
    #     0 个 DNS 包），下面这个 DNS 完全不参与；
    #   · 代理停掉：`~.` 消失，resolved 落到「default-route link 的 DNS + 这里的 DNS」。
    #
    # 所以这里必须是「加密 + 能解析国内域名」的服务器 —— 两个都是硬要求：
    #   · 明文：查询内容直接交给 ISP；
    #   · 断掉：代理挂的时候国内网站全部解析失败。
    # DoT（`#dns.alidns.com`）满足前者，alidns 满足后者。
    #
    # DNSOverTLS 必须是 opportunistic：`IP#hostname` 语法只在 DoT 开启时才生效，
    # 默认的 `no` 会让它静默退化成明文 53。用 opportunistic 而不是 yes，是因为
    # sing-box 的 tun DNS（172.19.0.2）没有 hostname，不该被强制 DoT。
    #
    # 代理模块（sib/miho）不再声明 DNS：它们接管查询靠的是 tun 的 routing domain，
    # 写 `DNS = [ "127.0.0.1" ]` 既从不起作用，又会在代理挂掉时拦住下面这层兜底。
    # dae 例外 —— 它不监听 :53，靠截获出网查询，由自己声明明文上游。
    services.resolved = {
      enable = true;
      settings.Resolve = {
        DNSSEC = false;
        DNSOverTLS = "opportunistic";
        DNS = lib.mkDefault [
          "223.5.5.5#dns.alidns.com"
          "223.6.6.6#dns.alidns.com"
        ];
        FallbackDNS = lib.mkDefault [
          "223.5.5.5#dns.alidns.com"
          "223.6.6.6#dns.alidns.com"
        ];
      };
    };

    # DHCP / RA 会把路由器的 DNS 塞进 per-link 配置，而这个 link 默认是
    # `Default Route: yes`。代理停掉时 resolved 会用它（实测 2026-10-27：
    # 停掉 sib 后 example.com 走 wlp1s0、明文 128ms 返回）。
    # `networkmanager.dns = "none"` 只控制 NM 是否写 resolv.conf，拦不住这条路，
    # 必须把 link DNS 本身覆盖掉。
    #
    # 代理正常时查询被 tun 的 `~.` 接管，这段不影响；代理挂掉时它是唯一的解析
    # 路径，所以也不能留明文。
    # dae 不加：它靠截获明文 DNS 查询工作，覆盖 link DNS 反而会让它看不到查询。
    networking.networkmanager.dispatcherScripts = lib.optionals
      (config.${namespace}.sib.enable || config.${namespace}.miho.enable)
      [
        {
          source = pkgs.writeShellScript "resolved-dns-no-plaintext" ''
            case "$2" in
              up|dhcp4-change|dhcp6-change) ;;
              *) exit 0 ;;
            esac
            [ -n "$1" ] || exit 0
            ${pkgs.systemd}/bin/resolvectl dns "$1" \
              223.5.5.5#dns.alidns.com 223.6.6.6#dns.alidns.com 2>/dev/null || true
          '';
        }
      ];

    # 1. NM 只管连接，不管 DNS
    networking.networkmanager.enable = true;
    networking.networkmanager.dns = lib.mkForce "none";
    networking.dhcpcd.enable = false;

    # 2. wlp1s0 继续 DHCP 拿地址。
    # DNS 由上面的 dispatcher 覆盖成加密上游 —— DHCP 给的 DNS 只是「拿到但不使用」，
    # 因为 resolved 的 per-link 配置会被覆盖，而 NM 本身不写 resolv.conf。
    networking.useDHCP = false;
    networking.interfaces.wlp1s0.useDHCP = true;
  };
}
