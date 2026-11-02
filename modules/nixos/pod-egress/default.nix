# build 节点 pod 出向 TCP 的透明接管（Dockerfile 的 RUN 不读任何 proxy 变量也能出网）。
#
# ── 为什么单独成一个模块 ────────────────────────────────────────────────
# 这条 nft 规则的作用点与「用哪个代理客户端」无关：它只把 pod 发起的 TCP 新连接
# DNAT 到本机的一个**固定端口**，谁在监听那个端口由客户端负责。
#
# 2026-10-28 之前这段规则写在 sib 模块里。于是 `sib.enable = false;
# miho.enable = true`（切客户端）之后，规则和监听端口一起消失，而**没有任何报错**：
# pod 出网从「透明接管」静默退回「全部超时」，只有 CI 构建失败时才被发现。
# 现在规则与端口住在这里，客户端只负责「按 capture 契约提供监听」，切换时由
# 求值期断言把关（见下面 assertions）。
#
# ── 为什么是 DNAT 而不是 REDIRECT ──────────────────────────────────────
# pod 的包是**转发**流量。REDIRECT 要求入接口上有可投递的本机地址，而宿主侧的
# cilium veth（lxc*）**没有 IPv4 地址** —— 计数器在涨、包被丢弃、pod 侧一律超时
# （2026-10-28 实测）。DNAT 到本机某个确定地址（dnatTarget）才能进 INPUT 并被
# 客户端的重定向入站接住；客户端靠 SO_ORIGINAL_DST（conntrack 保留的原始目的）
# 还原 pod 想连的地址。
#
# ── 为什么需要这条规则（客户端自己的捕获在转发路径上会丢包）───────────
# 两家客户端都想抓转发流量，但都抓不住 TCP：
#   · mihomo 在 `table inet mihomo` 的 prerouting（priority dstnat+1）装
#     `meta l4proto tcp redirect to :45669`；
#   · sing-box 在 `table inet sing-box` 的 prerouting_prematch 装 nfqueue。
# 前者对**从 veth 进来**的 TCP 无处投递（veth 没有 IPv4 地址），包被静默丢弃。
# 实测（2026-10-28，zen14，删掉本表后）：pod 的 SYN 出现在 `lxc*` 上，之后既没有
# Meta 出向、也没有任何回包，pod 侧 20s 超时。
# 本规则优先级更高（dstnat-5），抢在前面把 TCP DNAT 到本机端口，客户端才接得住。
# ⚠️ 所以这条规则是**绕开客户端 REDIRECT 在转发路径失效**的绕法，不是理论最优。
#    标准解法是让客户端用 tproxy 监听 + `ip rule fwmark` + `ip route local ... table 100`；
#    没采用的原因：那套策略路由要和 cilium 的 fwmark 规则、EasyTier 的路由表共存，
#    两台客户端都要重验，收益只是省掉 dnatTarget 一个配置项。
#
# ── 前置条件：cilium 必须关掉 bpf host routing ─────────────────────────
# 否则 pod 的包在 cilium 的 BPF 程序里就被转发出去，根本到不了 netfilter，
# 本规则的计数器永远是 0。声明在另一仓 system-manager-hinihao-net 的
# kubenix/build-node-egress.nix（CiliumNodeConfig `enable-host-legacy-routing=true`）。
#
# ── 没有 DNS 那一腿，UDP 也不在本规则里 ────────────────────────────────
# 本规则只管 TCP。pod 的 UDP（含 DNS）由客户端的 `ip rule … lookup 2022` 送进 TUN，
# 在 TUN 里被 DNS hijack / 代理接住（实测：pod 查 8.8.8.8 的包在 `Meta` 上以
# 198.18.0.1 为源出现，回包是 fakeip 应答）。
# 也就是说 pod 出网实际由**两套机制**拼起来：TCP 走本规则 + 客户端 redir 入站，
# UDP 走客户端 auto-route + TUN。原因见上一节（客户端抓不住转发的 TCP）。
#
# ── 为什么没有 DNS 那一腿（2026-10-28 实测后删除）──────────────────────
# 曾经还有一条「pod 的 :53 一律 DNAT 到客户端 DNS 入站」的规则。它有三个问题：
#   1. 它**抓不到集群 DNS 的原样查询**：pod → ClusterIP 的包在 cilium 的 TC 层
#      就已翻译成 CoreDNS 的 pod IP，规则的 dport 53 于是照样命中，把「已经翻译
#      好的」包又劫走一次 —— 结果每个客户端都必须自己实现「cluster 域名转发回
#      build-local CoreDNS」，谁漏了谁就把整个节点的 pod DNS 弄坏；
#   2. 它对「pod 用外部解析器」是黑的：DNAT 到客户端 DNS 入站后回包匹配不上
#      conntrack（源地址不是 DNAT 目标），现象是 8.8.8.8 一律超时 —— 比不接管更坏；
#   3. 不需要：pod 的 DNS 本来就走 kubelet 的 --cluster-dns（build-local CoreDNS，
#      上游是 DoT，答案不污染），而 stray 的出网 :53 由客户端 TUN 的 dns-hijack
#      接住（sib 实测：删掉本规则后 pod 查 8.8.8.8 拿到 fakeip 应答）。
# 结论：DNS 不属于这个模块的职责。集群内解析靠集群 DNS，别让代理客户端参与。
#
# ── 启动顺序：dnatTarget 是「别的单元创建的地址」 ─────────────────────────
# dnatTarget 通常是 EasyTier 的 tun 地址，开机时由 `easytier-<实例>.service`
# 建出来，与本单元没有任何先后关系。2026-11-01 nova13 冷启动实测：两个单元
# 同在 `before=k0sworker.service` 集合里并发起跑，本单元的地址校验先执行 →
# 「不是本机 IPv4 地址」→ 直接 failed，oneshot 不重试。
# 后果不是「这台机器的代理没了」而是**该节点 pod 出向 TCP 全灭**：cilium
# 转发路径上的 TCP 被客户端 nfqueue 抓住却无处投递（见上文 REDIRECT 一节），
# 包静默丢弃 → coredns 上游 DoT 超时 → registry 读 S3 失败 → CI 拉镜像
# ImagePullBackOff。
# 所以提供该地址的单元必须在 `afterUnits` 里显式声明（不猜、不 sleep）。
{
  config,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.podEgress;
  netPolicy = config.${namespace}.netPolicy;

  # 排除集与 TUN 的 route_exclude_address 同源（net-policy 单一事实源）：
  # 这些地址本来就不进代理，DNAT 过来只会让客户端再 direct 出去，白绕一圈。
  rules = pkgs.writeText "pod-egress.nft" ''
    table inet pod-egress {
      chain prerouting {
        type nat hook prerouting priority dstnat - 5; policy accept;
        # priority 必须小于客户端的捕获链：mihomo 是 dstnat+1、sing-box 是 dstnat-1，
        # 用 dstnat-5 保证本规则先跑（改大就会退化成「客户端先丢包」）。
        #
        # ⚠️ `iifname "lxc*"` 匹配的是 cilium 的 veth **命名约定**，不是语义
        #    （前缀由 cilium 的 --veth-prefix 决定，默认 lxc）。换成按 pod CIDR 匹配
        #    要把集群拓扑事实写进本模块，而且 VXLAN 入向还得额外排除 cilium_vxlan，
        #    所以保留约定匹配。兜底判据：pod-egress-check 的 transparent（前缀一变，
        #    这条规则不再命中，pod 出网立刻退回「全部超时」，那条判据当场红）。
        iifname "lxc*" ip daddr != { ${lib.concatStringsSep ", " netPolicy.bypassProxyAddresses} } \
          meta l4proto tcp counter dnat ip to ${cfg.dnatTarget}:${toString cfg.listenPort}
      }
    }
  '';

  # 无论启用与否都跑：关掉 podEgress 时把上一代留下的表删掉。
  # 否则「声明里已经关了，节点上还在劫持」——正是本仓库禁的那种残留状态。
  apply = pkgs.writeShellApplication {
    name = "pod-egress-apply";
    runtimeInputs = with pkgs; [
      nftables
      iproute2
      gnugrep
      gawk
      coreutils
    ];
    text = ''
      # nft -f 是 add 语义，重复执行会重复追加规则；先删后建保证幂等。
      nft delete table inet pod-egress 2>/dev/null || true

      ${lib.optionalString cfg.enable ''
        # afterUnits 只能保证顺序：EasyTier 是 Type=simple，systemd 认为它 active 的
        # 那一刻 tun 地址可能还没落盘（它没有 sd_notify 可用）。所以再有界等一下，
        # 实测窗口 < 1s；30s 是上限，超了才当真问题报错（再由 Restart 兜底）。
        for _ in $(seq 1 60); do
          ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 \
            | grep -Fxq ${cfg.dnatTarget} && break
          sleep 0.5
        done

        # DNAT 目标必须是本机地址。写成别的节点/写错一位数时，包会被送到别处或
        # 直接黑洞，而 nft 与 systemd 都不会报错 —— 唯一的征兆是「pod 连不上」。
        if ! ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -Fxq ${cfg.dnatTarget}; then
          echo "podEgress.dnatTarget=${cfg.dnatTarget} 不是本机 IPv4 地址（应为 kubelet 的 --node-ip）" >&2
          exit 1
        fi
        nft -f ${rules}
      ''}
    '';
  };
in
{
  options.${namespace}.podEgress = with lib; {
    enable = mkEnableOption "把本机 pod 的出向 TCP 透明接管到代理客户端";

    dnatTarget = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "10.144.150.3";
      description = ''
        DNAT 目标：本机的一个 IPv4 地址，通常就是 kubelet 的 `--node-ip`。
        必须是本机地址（宿主侧 veth 没有地址，REDIRECT 无处投递）。
      '';
    };

    listenPort = mkOption {
      type = types.port;
      default = 15001;
      description = ''
        客户端重定向入站的固定端口。**必须固定**：nft 规则在客户端启动前就要写好，
        读不到运行时自动分配的端口。
      '';
    };

    afterUnits = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "easytier-zen14-sg-prod.service" ];
      description = ''
        创建 `dnatTarget` 地址的 systemd 单元（通常是对应网络的 EasyTier 实例）。

        本单元启动时校验 `dnatTarget` 是本机地址；地址还没建出来就失败，而 oneshot
        不会自己重试。顺序只能在这里声明，不能靠 sleep 或「地址很早就有了」的假设。
        留空 = 该地址在开机早期就已存在（loopback 之类），不需要等待。
      '';
    };

    capture = {
      tcpRedirectPort = mkOption {
        type = types.nullOr types.port;
        default = null;
        internal = true;
        description = ''
          当前启用的客户端**实际**监听的 TCP 重定向端口，由客户端模块自己声明
          （sib / miho 各在 enable 时写一次）。不提供捕获面的客户端（dae）保持 null。

          这个值存在的唯一目的是让下面的断言有东西可比：把「nft 规则 DNAT 到的端口」
          和「客户端真的在监听哪」绑在一起，而不是靠两处字面量恰好相等。

          不用 readOnly：readOnly 会把本选项的 default 也算成一次定义，于是任何
          客户端的定义都会撞成「set multiple times」。两个客户端同时 enable 时，
          types.port 的合并自身就会报冲突，不需要 readOnly 兜这一层。
        '';
      };
    };
  };

  config = {
    assertions = [
      {
        # 物种：切了客户端但没接捕获面 —— 规则把 pod 的 TCP DNAT 到一个没人监听的
        # 端口，节点上所有 pod 出网静默全灭。2026-10-28 实测（sib → miho）。
        assertion = !cfg.enable || cfg.capture.tcpRedirectPort != null;
        message = ''
          ${namespace}.podEgress.enable = true，但没有客户端声明捕获面
          （${namespace}.podEgress.capture.tcpRedirectPort = null）。

          nft 规则会把 pod 的出向 TCP DNAT 到 ${toString cfg.listenPort}，而那个端口没有
          监听者 —— 表现为该节点所有 pod 出网超时。支持捕获面的客户端：sib / miho
          （二者择一 enable）；dae 不支持。
        '';
      }
      # 这里**故意不**断言「capture 端口 == listenPort」：两个客户端都直接读同一个
      # listenPort 选项去配置监听，相等是构造出来的，那样的断言恒真（= 没有闸门）。
      # 「客户端真的在那个端口上监听」只能看运行态：`nix run .#pod-egress-check` 的
      # transparent 判据（在跨仓的 system-manager-hinihao-net 里）。
      {
        # 物种：dnatTarget 漏配（null 会被插值成字符串 "null" 或让规则无法求值）。
        assertion = !cfg.enable || cfg.dnatTarget != null;
        message = ''
          ${namespace}.podEgress.enable 需要同时给 dnatTarget（本机的一个 IPv4 地址，
          通常就是 kubelet 的 --node-ip）。
        '';
      }
    ];

    systemd.services.pod-egress = {
      description = "Install nftables rules that redirect pod egress TCP to the local proxy";
      wantedBy = [ "multi-user.target" ];
      # 规则要在 kubelet 起 pod 之前就位，否则开机后的一小段时间里 pod 出网是直连
      # （能通，但不经代理，且看不出来）。
      before = [ "k0sworker.service" ];
      # 地址由 afterUnits 里的单元创建（见模块头部「启动顺序」一节）。
      after = cfg.afterUnits;
      wants = cfg.afterUnits;
      # 万一起跑时地址还没落盘（例如 sops 渲染慢），按 10s 间隔重试 60 次
      # （10 分钟）后放弃 —— 这种持续失败属于真问题，不该永久刷日志。
      startLimitIntervalSec = 600;
      startLimitBurst = 60;
      # 脚本里嵌了规则文件的 store 路径，规则内容一变脚本路径就变 —— 它自己就是触发器。
      restartTriggers = [ apply ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 10;
        ExecStart = lib.getExe apply;
      };
    };
  };
}
