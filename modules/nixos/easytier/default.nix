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
  easytierIpByHost = {
    zen14 = "10.144.200.2";
    nova13 = "10.144.200.3";
  };
  easytierIp = easytierIpByHost.${hostName} or null;
  useMultiInstancePortal = hostName == "zen14" && easytierIp != null;

  # P2P 行为参数 —— zen14 / nova13 两节点的**单一来源**。
  #
  # 背景（2026-10-11 实测）：两机因 `disable_p2p` 且从未声明 `need_p2p`，
  # 被 EasyTier 归入官方组合表里最后一行「彻底安静，只走中继，不建任何 P2P」
  # 的语义 —— 两机永不直连，流量全部绕北京 ali 中转：
  #     easytier-cli peer → nova13  cost=relay(2)  lat=98ms  rx/tx=0 B
  # 根因是 2026-05-12（7b0b323）为压制「ET 拿 cilium/Meta 虚拟地址当候选打洞」
  # 而一并关掉了普通 P2P —— 那一步是过度的：真正挡住递归路径的是 bind_device
  # （连接 socket 只从物理网卡出，报文不会拐进 cilium 隧道）。
  #
  # 官方 p2p-optimize 文档给的组合正是本需求（「只想和特定节点建 P2P，
  # 不想被普通节点打扰」）：
  #   · disable_p2p  不主动连普通节点，普通节点也不会主动来连（挡住无关节点）
  #   · need_p2p     声明「请主动来连我」——disable_p2p 下**仍会**与 need_p2p 节点互连
  # 两者叠加 = 只在 zen14 ↔ nova13 之间建 P2P，其余仍走 relay。
  #
  # ⚠️ zen14 是**移动设备**：每天都可能换网络，两机**大多数时候不在同一局域网**，
  #    且 zen14 会随时下线。所以本配置：
  #      · **不写死任何对方地址**（LAN IP / 公网 IP 都不写）—— 写死必失效；
  #      · 依赖 need_p2p 的**动态打洞**：
  #          同 LAN  → 内网地址直连（实测 4~13ms）
  #          不同网络 → 走各自 NAT 的公网打洞（实测同城 80ms / 跨省更差）
  #          打不通  → 自动退回经 ali 的 relay，功能不中断（只是慢）
  #    也就是说：**能不能直连取决于当时的网络，但不影响可用性**。
  #    「同 LAN 4~13ms」只是最好情况，不是本配置的收益前提。
  etFlags = {
    accept_dns = true;
    bind_device = true;
    disable_p2p = true;
    need_p2p = true;
  };
  # 渲染成 TOML `[flags]` 段。两台机器共用，避免"同一语义两处各写一份"
  # （改这次 need_p2p 就得同时改 TOML 与 --need-p2p 两处，正是漂移的温床）。
  renderFlags = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (k: v: "${k} = ${lib.boolToString v}") etFlags
  );
in
{
  # 单实例模式：保留原有行为，给非 zen14 主机使用。
  sops.templates."easytier-config" = lib.mkIf (easytierIp != null && !useMultiInstancePortal) {
    content = ''
      instance_name = "${hostName}"

      [network_identity]
      network_name = "${config.sops.placeholder."easytier/ali/network_name"}"
      network_secret = "${config.sops.placeholder."easytier/ali/network_secret"}"

      [[peer]]
      uri = "${config.sops.placeholder."easytier/ali/peer"}"

      [flags]
      ${renderFlags}
    '';
  };

  # multi-instance portal：zen14 用 config-dir 方式托管单实例。
  sops.templates."easytier-zen14-config" = lib.mkIf useMultiInstancePortal {
    content = ''
      instance_name = "zen14"
      ipv4 = "${easytierIp}"
      listeners = [
        "tcp://0.0.0.0:11010",
        "udp://0.0.0.0:11010",
        "wg://0.0.0.0:11011",
        "quic://0.0.0.0:11012",
        "ws://0.0.0.0:11011/",
        "wss://0.0.0.0:11012/",
        "faketcp://0.0.0.0:11013",
      ]

      [network_identity]
      network_name = "${config.sops.placeholder."easytier/ali/network_name"}"
      network_secret = "${config.sops.placeholder."easytier/ali/network_secret"}"

      [[peer]]
      uri = "${config.sops.placeholder."easytier/ali/peer"}"

      [flags]
      ${renderFlags}
    '';
  };

  # 让 easytier-cli 进入系统 PATH，便于直接调试和查询实例。
  environment.systemPackages = lib.mkIf (easytierIp != null) [ pkgs-unstable.easytier ];

  # multi-instance portal：zen14 用 config-dir 模式，方便后续加新实例。
  systemd.services."easytier-easytier-net-zen14" = lib.mkIf useMultiInstancePortal (
    let
      configDir = "/run/easytier-multi";
      zen14Config = config.sops.templates."easytier-zen14-config".path;
      startScript = pkgs.writeShellScript "easytier-multi-start" ''
        set -euo pipefail

        ${pkgs.coreutils}/bin/install -d -m 0700 ${configDir}
        ${pkgs.coreutils}/bin/ln -sfn ${zen14Config} ${configDir}/zen14.toml

        exec ${pkgs-unstable.easytier}/bin/easytier-core \
          --config-dir ${configDir} \
          --rpc-portal 127.0.0.1:15888
      '';
    in
    {
      description = "EasyTier Daemon - easytier-net-zen14 (multi-instance portal)";
      wants = [
        "network-online.target"
        "nss-lookup.target"
      ];
      after = [
        "network-online.target"
        "nss-lookup.target"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        StateDirectory = "easytier/easytier-net-zen14";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/easytier/easytier-net-zen14";
        ExecStart = startScript;
      };
    }
  );

  # 非 multi-instance 的主机保留原有单实例服务。
  services.easytier = lib.mkIf (easytierIp != null && !useMultiInstancePortal) {
    enable = true;
    package = pkgs-unstable.easytier;
    instances."easytier-net-${hostName}" = {
      # ⚠️ flags（accept_dns / bind_device / disable_p2p / need_p2p）经 configFile 的
      #    `[flags]` 段下发，**不在这里重复写 CLI 参数** —— 两处各写一份正是过去
      #    漂移的成因（改 need_p2p 时要记得同时改两个地方，漏一处就静默不生效）。
      #    configFile 与 extraArgs 同源（etFlags），由 Nix 保证一致。
      extraArgs = [
        "-i"
        easytierIp
        "--rpc-portal"
        "127.0.0.1:15888"
      ];
      configFile = "${config.sops.templates."easytier-config".path}";
    };
  };
}
