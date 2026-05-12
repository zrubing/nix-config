{
  config,
  inputs,
  lib,
  system,
  ...
}:
let
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  hostName = config.networking.hostName;
  easytierIpByHost = {
    zen14 = "10.144.200.2";
    nova13 = "10.144.200.3";
  };
  easytierIp = easytierIpByHost.${hostName} or null;
  easytierInstanceName = "easytier-net-${hostName}";
in
{

  # # 导入不稳定版本的 模块
  # imports = [
  #   "${inputs.nixpkgs-unstable}/nixos/modules/services/networking/easytier.nix"
  # ];

  sops.templates."easytier-config" = lib.mkIf (easytierIp != null) {
    content = ''
      instance_name = "${hostName}"

      [network_identity]
      network_name = "${config.sops.placeholder."easytier/ali/network_name"}"
      network_secret = "${config.sops.placeholder."easytier/ali/network_secret"}"

      [[peer]]
      uri = "${config.sops.placeholder."easytier/ali/peer"}"
    '';
  };

  services.easytier = lib.mkIf (easytierIp != null) {
    enable = true;
    package = pkgs-unstable.easytier;
    instances.${easytierInstanceName} = {
      extraArgs = [
        "-i"
        easytierIp
        "--accept-dns"
        "true"
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
