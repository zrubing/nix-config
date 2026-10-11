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
      # 新集群 hinihao-sg-prod 的集群 ET（网关 hinihao-sg-prod-net）。
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
  # 背景（2026-10-11 实测）：节点因 `disable_p2p` 且从未声明 `need_p2p`，
  # 被 EasyTier 归入官方组合表里最后一行「彻底安静，只走中继，不建任何 P2P」
  # 的语义 —— 永不直连，流量全部绕北京 ali 中转：
  #     easytier-cli peer → 对端 cost=relay(2)  lat=98ms  rx/tx=0 B
  # 根因是 2026-05-12（7b0b323）为压制「ET 拿 cilium/Meta 虚拟地址当候选打洞」
  # 而一并关掉了普通 P2P —— 那一步是过度的：真正挡住递归路径的是 bind_device
  # （连接 socket 只从物理网卡出，报文不会拐进 cilium 隧道）。
  #
  # 官方 p2p-optimize 文档给的组合正是本需求（「只想和特定节点建 P2P，
  # 不想被普通节点打扰」）：
  #   · disable_p2p  不主动连普通节点，普通节点也不会主动来连（挡住无关节点）
  #   · need_p2p     声明「请主动来连我」——disable_p2p 下**仍会**与 need_p2p 节点互连
  # 两者叠加 = 只在声明了 need_p2p 的节点之间建 P2P，其余仍走 relay。
  #
  # ⚠️ zen14 是**移动设备**：每天都可能换网络，两机**大多数时候不在同一局域网**，
  #    且 zen14 会随时下线。所以本配置：
  #      · **不写死任何对方地址**（LAN IP / 公网 IP 都不写）—— 写死必失效；
  #      · 依赖 need_p2p 的**动态打洞**：
  #          同 LAN  → 内网地址直连（实测 4~13ms）
  #          不同网络 → 走各自 NAT 的公网打洞（实测同城 80ms / 跨省更差）
  #          打不通  → 自动退回经网关的 relay，功能不中断（只是慢）
  #    也就是说：**能不能直连取决于当时的网络，但不影响可用性**。
  #    「同 LAN 4~13ms」只是最好情况，不是本配置的收益前提。
  etFlags = {
    accept_dns = true;
    bind_device = true;
    disable_p2p = true;
    need_p2p = true;
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
