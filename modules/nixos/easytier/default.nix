{
  config,
  inputs,
  lib,
  pkgs,
  system,
  ...
}:
let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit system;
    overlays = [ (import ../../../overlays/easytier-bin { }) ];
  };

  hostName = config.networking.hostName;

  # ── 每台机器加入的 ET 网络（**唯一事实源**）─────────────────────────────
  #
  # 一台机器可以同时在**多个** ET 网络里：每个网络 = 一个独立实例 = 一个 tun 设备。
  # 由 nixpkgs 的 `services.easytier.instances` 渲染成「一实例一 systemd service」
  # （`easytier-<实例名>.service`），无需手写 portal/启动脚本。
  #
  # 字段：
  #   ipv4      该实例在本网络的虚拟 IP（网内可见，非秘密，故留在代码里）
  #   portBase  监听端口基数，占用 portBase..portBase+3（tcp/udp、wg、quic、faketcp）
  #
  # ⚠️ **端口必须逐实例错开**：所有实例跑在同一台机器上，绑同一组端口必然冲突。
  #    判据见 `networks` 下方的 assertion —— 冲突会在求值阶段就报错，不会等到运行时。
  #
  # ⚠️ 为什么需要「一台机器多个网络」：
  #    zen14 迁入新集群（sg-prod）后，若只留在 sg-prod，就**再也够不到 nova13**
  #    （nova13 在 ali 网络里）—— 两机分属不同 ET 网络时，它们之间连 relay 都没有
  #    （relay 只存在于同一网络内部）。实测：`ping 10.144.200.3` 100% 丢包、
  #    `easytier-cli peer` 里 nova13 出现 0 次。
  #    两台都是家用机，需要经 ali 中转互通，故让它们共处 ali 网络。
  etNetworksByHost = {
    zen14 = [
      # 新集群 acme-prod 的集群 ET（网关 acme-prod-net）。
      # kubelet 的 --node-ip 用的是这个地址，**不可随意改动**。
      {
        network = "sg-prod";
        ipv4 = "10.144.150.3";
        portBase = 11010;
      }
      # 老集群的 Build ET（网关 ali）。恢复 zen14 迁走前的地址 10.144.200.2，
      # 使 zen14 ↔ nova13 重新同网络，从而能直连/经 ali 中转。
      {
        network = "ali";
        ipv4 = "10.144.200.2";
        portBase = 12010;
      }
    ];
    nova13 = [
      # 老集群 Build ET（原有归属，保持不变）。
      {
        network = "ali";
        ipv4 = "10.144.200.3";
        portBase = 11010;
      }
      # 新集群 SG-prod（2026-10-12 加入，成为该集群第二个 build 节点）。
      # kubelet 的 --node-ip 用这个地址。
      {
        network = "sg-prod";
        ipv4 = "10.144.150.4";
        portBase = 12010;
      }
    ];
  };

  # 本机的实例列表；未登记的机器 = 不参与任何 ET 网络。
  myNetworks = etNetworksByHost.${hostName} or [ ];

  # 端口不重叠校验 —— 同一台机器内两两比较。
  # 放在求值阶段：配错网络时 `nixos-rebuild` 立刻失败，而不是运行时才暴露
  # 「第二个实例起不来、第一个实例被顶掉」这类静默故障。
  portRange = n: lib.range n.portBase (n.portBase + 3);
  overlaps = a: b: lib.any (p: lib.elem p (portRange b)) (portRange a);
  # 取所有两两组合（i < j），保留网络属性本身而非下标。
  allPairs = lib.concatLists (
    lib.imap0 (i: a: map (b: { inherit a b; }) (lib.drop (i + 1) myNetworks)) myNetworks
  );
  portConflicts = map (p: "${p.a.network} ↔ ${p.b.network} (${toString p.a.portBase}/${toString p.b.portBase})") (
    lib.filter (p: overlaps p.a p.b) allPairs
  );

  # ── ET 网络凭据来源 ───────────────────────────────────────────────────
  #
  # 三个值（network_name / network_secret / peer）**全部来自 sops**：
  # peer 里含网关公网 IP，而本仓库是公开 GitHub 仓库，写进代码即全球可见。
  #
  # ⚠️ 新增网络必须**同时**改两处，缺一处 `nixos-rebuild` 直接失败：
  #      1. ./default.nix（本文件）的 etNetworksByHost
  #      2. modules/nixos/sops/default.nix（声明解密哪些 key）
  secretPrefix = network: "easytier/${network}";

  # P2P 行为参数 —— 所有节点、所有网络的单一来源。
  #
  # 结论：**不建 P2P，全部走中继**（ali 28ms / sg 网关 107~274ms）。
  #
  # 演进史（别再翻烧饼，两条都实测过）：
  #   2026-05-12（7b0b323）关 P2P —— 为压制「ET 拿 cilium/Meta 虚拟地址当候选拨号」，
  #                          但当时认定 bind_device 就够，于是……
  #   2026-10-11 开 need_p2p —— 想恢复直连。
  #   2026-10-22 回退到「只走中继」—— 递归路径**根本挡不住**，见下。
  #
  # 根因（2026-10-22 实测，两个独立缺陷叠加）：
  #   1) 候选地址污染：ET 的候选 = 本机所有「非 p2p、非 tun、up、有 IP」的网卡
  #      （easytier/src/common/network.rs: InterfaceFilter::filter_iface）。
  #      tun0/tun1/Meta 被正确排除，但 **cilium_host（10.246.x）符合条件**，
  #      于是被当 P2P 候选广播出去。对端居然连得上 —— 因为 cilium overlay
  #      本身就跑在 ET 隧道（tun0）上，形成自指链：
  #          ali ET → cilium(vxlan) → sg-prod ET → nova13
  #      另外 local_ipv4() 用 connect 8.8.8.8 探测本机地址，被 mihomo TUN
  #      劫持成 198.18.0.1，这个假地址也被当成本机地址广播（日志可见对
  #      udp://198.18.0.1:12010 的拨号，甚至两个实例互连）。
  #   2) 选路只看 cost 不看质量：p2p(0) 恒优于 relay(2)，且死链上报
  #      lat=0.00ms —— 越烂的链路看起来越优，永不回落到中继。
  #      （所以 latency_first 也救不了：它会优先选那条 0.00ms 的死链。）
  #
  # bind_device 挡不住 1)：它只约束发包网卡，往本机虚拟地址拨号不需要出物理网卡。
  # ET 2.6.4 的 FlagsInConfig 里没有候选地址过滤项，1) 无法从配置侧修。
  #
  # 实测症状（2026-10-22 16:00）：
  #   · ping 10.144.200.3 → 90% 丢包，RTT 397~1003ms；ssh 三次 28.4s/0.22s/0.23s
  #   · ali 网络 nova13：p2p 308→1024ms、62~66% 丢包，remote 全是 10.246.3.53；
  #     10 分钟重连 77 次
  #   · sg-prod 网络 zen14↔nova13：p2p 0.00ms / 100% 丢包；tun0 TX 13.1GB、
  #     dropped 405 万 —— cilium vxlan 被灌进死链
  #   · 同期 ali 网关 28.9ms / 0% 丢包，中继一直是健康的
  #
  # 代价（已知并接受）：sg-prod 内 zen14↔nova13 的 cilium vxlan 要绕 SG 网关，
  # 跨节点 pod 流量延迟上升；但此前那条直连是 100% 丢包的，绕路至少可用。
  #
  # 若将来真要恢复直连，前提是让 ET 不把 cilium/Meta 地址当候选 —— 2.6.4 做不到。
  etFlags = {
    accept_dns = true;
    bind_device = true;
    # 不主动连普通节点，也不对任何广播候选拨号。
    disable_p2p = true;
    # 必须缺省：disable_p2p 下 need_p2p 仍会触发互连，等于把 P2P 又打开。
    need_p2p = false;
  };
  # 渲染成 TOML `[flags]` 段。所有实例共用，避免"同一语义两处各写一份"
  # （改一次 flag 要同时改 TOML 与 CLI 两处，正是过去漂移的成因）。
  renderFlags = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (k: v: "${k} = ${lib.boolToString v}") etFlags
  );

  # 单个实例名的渲染：`<主机名>-<网络名>`，便于在 `easytier-cli` 与
  # `systemctl status` 里一眼看出「哪台机器的哪个网络」。
  instanceName = net: "${hostName}-${net.network}";

  # 实例配置（TOML 全文）。用 configFile 方式而非模块的 settings：
  # 因为 network_secret 是 sops 占位符，只有经 sops.templates 渲染才会被替换成真值。
  instanceConfig = net: ''
    instance_name = "${instanceName net}"
    ipv4 = "${net.ipv4}"
    listeners = [
      "tcp://0.0.0.0:${toString net.portBase}",
      "udp://0.0.0.0:${toString net.portBase}",
      "wg://0.0.0.0:${toString (net.portBase + 1)}",
      "quic://0.0.0.0:${toString (net.portBase + 2)}",
      "ws://0.0.0.0:${toString (net.portBase + 1)}/",
      "wss://0.0.0.0:${toString (net.portBase + 2)}/",
      "faketcp://0.0.0.0:${toString (net.portBase + 3)}",
    ]

    [network_identity]
    network_name = "${config.sops.placeholder."${secretPrefix net.network}/network_name"}"
    network_secret = "${config.sops.placeholder."${secretPrefix net.network}/network_secret"}"

    [[peer]]
    uri = "${config.sops.placeholder."${secretPrefix net.network}/peer"}"

    [flags]
    ${renderFlags}
  '';
in
{
  assertions = [
    {
      assertion = portConflicts == [ ];
      message = ''
        ${hostName} 的 ET 实例监听端口冲突（每个实例占 portBase..portBase+3）：
        ${lib.concatMapStringsSep "\n" (c: "  ${c}") portConflicts}
        请给 etNetworksByHost.${hostName} 的实例分配不重叠的 portBase。
      '';
    }
  ];

  # 一实例一 sops 模板 —— sops-nix 在激活时把占位符替换成真值，
  # 落到 /run/secrets/rendered/easytier-<实例名>（0400 root）。
  #
  # `restartUnits` 是 sops-nix 的机制（**模板**上的选项，不是服务上的）：
  # 渲染结果变化时重启对应实例 —— 否则模板换了文件、进程仍读旧配置，
  # 表现为「配置对了但 ET 行为没变」。
  sops.templates = lib.genAttrs (map instanceName myNetworks) (name: {
    content = instanceConfig (lib.findFirst (n: instanceName n == name) null myNetworks);
    restartUnits = [ "easytier-${name}.service" ];
  });

  # 经 nixpkgs 原生 `services.easytier.instances` 启动：每实例一个 systemd service
  # （`easytier-<实例名>.service`），无需手写 portal / 启动脚本。
  #
  # ⚠️ 不走模块的 `settings`：network_secret 是 sops 占位符，只有 sops.templates
  #    渲染后的文件才含真值，故整份 TOML 走 `configFile`。
  services.easytier = lib.mkIf (myNetworks != [ ]) {
    enable = true;
    package = pkgs-unstable.easytier;
    instances = lib.genAttrs (map instanceName myNetworks) (name: {
      configFile = config.sops.templates."${name}".path;
      extraArgs = [
        "--rpc-portal"
        # 逐实例错开的 RPC 端口（portBase + 10），便于 `easytier-cli -p` 分别查询。
        "127.0.0.1:${toString ((lib.findFirst (n: instanceName n == name) null myNetworks).portBase + 10)}"
      ];
    });
  };

  # 让 easytier-cli 进入系统 PATH，便于直接调试和查询实例。
  environment.systemPackages = lib.mkIf (myNetworks != [ ]) [ pkgs-unstable.easytier ];

  # ⚠️ 必须 before k0sworker：kubelet 通过 ET 隧道访问 apiserver。
  #    隧道未就绪时 k0s 先起，kubelet 会连不上 apiserver 并反复重试。
  systemd.services = lib.genAttrs (map (n: "easytier-${instanceName n}") myNetworks) (_: {
    before = [ "k0sworker.service" ];
  });
}
