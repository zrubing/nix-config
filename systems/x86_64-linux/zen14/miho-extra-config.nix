{
  dns = {
    # resolved 上游配置为 127.0.0.1:53（networking/default.nix），基础配置里
    # listen 0.0.0.0:1053 与之错配导致 DNS 链路断裂（mihomo 收不到 resolved 查询）。
    # 此处覆盖回 127.0.0.1:53。
    listen = "127.0.0.1:53";
    # ⚠️ 不要在这里加 +.cluster.local 的 nameserver-policy：
    # mihomo 的 DNS 上游查询带 fwmark 绕过 cilium 的 ClusterIP 负载均衡
    # （走 main 表默认路由黑洞），只有 coredns pod IP 可达，但 pod IP 会变。
    # build 节点解析 cluster.local 的唯一实际场景是 containerd 拉镜像，
    # 已用 containerd mirror（见 default.nix 的 k0s/containerd.d/mirrors.toml）直连
    # 本机 NodePort 解决，不依赖 DNS。
  };

  tun = {
    route-exclude-address = [
      "127.0.0.2/32"
      "127.0.0.3/32"
      # Kubernetes ServiceCIDR / PodCIDR must bypass mihomo TUN on build nodes.
      # Host processes such as containerd need direct access to kube-dns and Zot.
      "10.96.0.0/12"
      "10.244.0.0/16"
      # EasyTier / cluster overlay addresses.
      "10.144.0.0/16"
    ];
  };
}
