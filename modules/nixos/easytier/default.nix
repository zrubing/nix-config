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
in
{
  # # 导入不稳定版本的 模块
  # imports = [
  #   "${inputs.nixpkgs-unstable}/nixos/modules/services/networking/easytier.nix"
  # ];

  # 单实例模式：保留原有行为，给非 zen14 主机使用。
  sops.templates."easytier-config" = lib.mkIf (easytierIp != null && !useMultiInstancePortal) {
    content = ''
      instance_name = "${hostName}"

      [network_identity]
      network_name = "${config.sops.placeholder."easytier/ali/network_name"}"
      network_secret = "${config.sops.placeholder."easytier/ali/network_secret"}"

      [[peer]]
      uri = "${config.sops.placeholder."easytier/ali/peer"}"
    '';
  };

  # multi-instance portal：把 zen14 + zen-sg 放进同一个 easytier-core 进程。
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
      accept_dns = true
      bind_device = true
      disable_p2p = true
    '';
  };

  sops.templates."easytier-zen-sg-config" = lib.mkIf useMultiInstancePortal {
    content = ''
      instance_name = "easytier-zen-sg"
      ipv4 = "10.144.210.2"
      listeners = ["tcp://0.0.0.0:18135"]

      [network_identity]
      network_name = "zen-sg"
      network_secret = "${config.sops.placeholder."easytier/zen-sg/network_secret"}"

      [[peer]]
      uri = "${config.sops.placeholder."easytier/zen-sg/peer"}"

      [flags]
      accept_dns = false
      disable_p2p = true
    '';
  };

  # 让 easytier-cli 进入系统 PATH，便于直接调试和查询实例。
  environment.systemPackages = lib.mkIf (easytierIp != null) [ pkgs-unstable.easytier ];

  # multi-instance portal：一个 easytier-core 托管两个实例，CLI 直接连默认端口即可按实例名选。
  systemd.services."easytier-easytier-net-zen14" = lib.mkIf useMultiInstancePortal (
    let
      configDir = "/run/easytier-multi";
      zen14Config = config.sops.templates."easytier-zen14-config".path;
      zenSgConfig = config.sops.templates."easytier-zen-sg-config".path;
      startScript = pkgs.writeShellScript "easytier-multi-start" ''
        set -euo pipefail

        ${pkgs.coreutils}/bin/install -d -m 0700 ${configDir}
        ${pkgs.coreutils}/bin/ln -sfn ${zen14Config} ${configDir}/zen14.toml
        ${pkgs.coreutils}/bin/ln -sfn ${zenSgConfig} ${configDir}/easytier-zen-sg.toml

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
      extraArgs = [
        "-i"
        easytierIp
        "--accept-dns"
        "true"
        "--rpc-portal"
        "127.0.0.1:15888"
        # k0s build/proxy 节点同时有 cilium_host/PodCIDR、mihomo Meta 和 EasyTier tun0。
        # EasyTier 自动 P2P 会把这些内部/虚拟地址也作为候选连接地址传播，
        # 典型表现是 zen14 反复尝试 tcp://10.244.x.x:<port> 连接 nova13，
        # 形成“集群网络承载 VPN，VPN 又承载集群控制面”的递归路径，导致
        # apiserver/konnectivity 偶发 EOF、deadline exceeded。
        # 这里让连接 socket 绑定到物理出口，并禁用自动 P2P 打洞，只保留到
        # 声明 peer 的稳定连接，避免选择 cilium/Meta/tun 等虚拟路径。
        "--bind-device"
        "true"
        "--disable-p2p"
        "true"
      ];
      configFile = "${config.sops.templates."easytier-config".path}";
    };
  };
}
