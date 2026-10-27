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

  config =
    let
      # 唯一允许的兜底 DNS：加密（`IP#hostname` 要配合 DNSOverTLS != no 才生效）
      # + 能解析国内域名。两处入口（dispatcher / oneshot）共用同一份。
      dnsNoPlaintext = pkgs.writeShellScript "resolved-dns-no-plaintext" ''
        set -u
        SERVERS="223.5.5.5#dns.alidns.com 223.6.6.6#dns.alidns.com"

        # 职责：只给物理网卡的 link DNS 设加密兜底。
        #
        # 它与代理的分工：物理网卡的 DNS 是「没人管的时候用我」（代理停机时仍能
        # 解析国内域名且不泄露明文）；代理 tun 的 DNS 是「所有查询都问我」，必须
        # 指向代理自己。两者语义相反，不能合并。详见 docs/net-invariants.md
        # 的「谁拥有接口的 DNS」。
        #
        # 判据见 apply() 内部的两道；2026-10-27 本脚本曾把 singtun0 的 DNS 改成
        # 阿里，导致 fakeip 完全失效，域名答真实 IP 后命中「非内网 → 直连」。
        apply() {
          [ -n "''${1:-}" ] || return 0

          # 判据一（语义）：带 ~. 路由域的接口是代理 tun——它接管了这台机器的
          # 全部解析，DNS 必须由它自己提供。碰它等于剥夺 fakeip。
          #
          # 为什么这是主判据而不是「防未来」：sing-box 从 1.13.2 起（issue #3878，
          # 至今 open）会在 TUN 起来后主动写 systemd-resolved 的 per-link DNS
          #（推导 tun 地址的下一个 IP，如 172.19.0.1/30 → 172.19.0.2）并加 `~.`
          # 域。这是它让 fakeip 生效的既定机制，不是副作用；官方给的控制点只有
          # tun.dns_mode（disabled / native / hijack），而我们需要 hijack。
          # 一旦这里改写，查询不再进 sing-box → 域名答真实 IP → 命中
          #「非内网 → 直连」→ 本该走代理的流量变成直连超时。
          #
          # 它同时也是真实的运行时路径：Wi-Fi 重连、NetworkManager 重启都会再
          # 触发 up 事件，那时 tun 早已带上 ~.，下面的结构判据看不到任何特征。
          case "$(${pkgs.systemd}/bin/resolvectl domain "$1" 2>/dev/null)" in
            *"~."*) return 0 ;;
          esac

          # 判据二（结构兜底）：sing-box 创建 tun 后先无 ~.、随后才设，dispatcher
          # 可能赶在这两步中间。此时判据一看不到特征，只能靠接口本身的性质区分：
          # /sys/class/net/<if>/device 只对真实硬件存在，tun / veth / cilium /
          # lxc 都没有。
          [ -e "/sys/class/net/$1/device" ] || return 0

          ${pkgs.systemd}/bin/resolvectl dns "$1" $SERVERS 2>/dev/null || true
        }

        # dispatcher 调用：$1=接口 $2=动作（只处理拿到地址的事件）
        if [ "$#" -ge 2 ]; then
          case "$2" in
            up|dhcp4-change|dhcp6-change) apply "$1" ;;
          esac
          exit 0
        fi

        # 启动时调用：遍历所有接口，apply 内部按 sysfs 判据过滤。
        # 不用 nmcli：它的 TYPE 是简化名（wifi / ethernet / tun），与
        # NetworkManager 的全名（802-11-wireless / 802-3-ethernet）不同，
        # 早期版本按全名过滤导致启动分支从未生效过。
        for dev in /sys/class/net/*; do
          apply "''${dev##*/}"
        done
      '';
    in
    {

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
    #
    # 两个入口用同一个脚本：
    #   · dispatcher —— 处理 link 变化（换 Wi-Fi、DHCP 续租）；
    #   · oneshot 服务 —— 处理开机和 rebuild。只有 dispatcher 不够：
    #     nixos-rebuild 不会产生 DHCP 事件，实测 nova13 激活后 wlp1s0 仍挂着
    #     DHCP 的 192.168.124.1，明文 53 継续在跑。
    systemd.services.resolved-dns-no-plaintext = lib.mkIf
      (config.${namespace}.sib.enable || config.${namespace}.miho.enable)
      {
        description = "Force encrypted DNS upstream on links that got DHCP DNS";
        after = [ "NetworkManager.service" ];
        wants = [ "NetworkManager.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        serviceConfig.ExecStart = dnsNoPlaintext;
        path = [ pkgs.networkmanager ]; # 脚本无参数时用 nmcli 枚举接口
      };

    networking.networkmanager.dispatcherScripts = lib.optionals
      (config.${namespace}.sib.enable || config.${namespace}.miho.enable)
      [ { source = dnsNoPlaintext; } ];

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
