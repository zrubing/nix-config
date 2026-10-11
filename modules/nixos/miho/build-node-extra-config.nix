# Build 节点（zen14 / nova13）共用的 mihomo 覆盖配置。
#
# ⚠️ **单一事实源**：两台机器的 `miho-extra-config.nix` 曾经各写一份，结果是
#    nova13 漏了 `127.0.0.2/3`（tcp-forward 转发端口被 mihomo 抢走）和
#    集群节点 VPC 网段（跨节点 Cilium VXLAN 全断）—— 而 zen14 有。
#    「同一语义两处各写一份」正是漂移的温床，故收敛到本文件。
#
# 消费方：systems/x86_64-linux/{zen14,nova13}/default.nix 的
#         `${namespace}.miho.extraConfig = import <本文件>;`
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
    # 已用 containerd mirror（见各机 default.nix 的 k0s/containerd.d/mirrors.toml）
    # 直连本机 NodePort 解决，不依赖 DNS。
  };

  tun = {
    # ── 排除判据 ────────────────────────────────────────────────────────
    #
    # ⚠️ 判据不是「网段属不属于集群」，而是
    #    **「这个包会不会被主机自己的路由表送出去」**：
    #
    #   要排除的（会经主机路由表 → 可能被 Meta 设备劫持）：
    #     · ET overlay（10.144.0.0/16）
    #     · 集群**节点 InternalIP**（腾讯云 VPC 子网）—— Cilium
    #       routingMode=tunnel 用 InternalIP 作 VXLAN 隧道端点
    #     · tcp-forward 的 loopback 地址（127.0.0.2/3）
    #
    #   刻意**不**排除的（走不到路由表）：
    #     · serviceCIDR / podCIDR —— ClusterIP 在 **socket 层就被 Cilium eBPF
    #       翻译掉**，发生在路由决策之前。实测 zen14 未排除新集群的
    #       10.112.0.0/12 仍能直连 10.112.0.10:53。
    route-exclude-address = [
      # tcp-forward 的 loopback 监听地址（test-mysql@127.0.0.2、
      # prod-mysql@127.0.0.3，见各机 default.nix 的 tcp-forward.forwards）。
      # 不排除 → 本机连不上自己的转发端口。
      "127.0.0.2/32"
      "127.0.0.3/32"

      # 老集群（hinihao-net）的 serviceCIDR / podCIDR。
      # 2026-10-12 两机均已迁入 hinihao-sg-prod，这两条**已失效**，保留的理由：
      # 它们无害（只是多两条直连路由），且让迁移痕迹可见、可追溯。
      "10.96.0.0/12"
      "10.244.0.0/16"

      # EasyTier overlay —— 必须排除，否则 ET 自己的包进代理，全网不通。
      "10.144.0.0/16"

      # ── 新集群 hinihao-sg-prod 的**节点内网网段**（腾讯云 VPC 两个子网）──
      #
      # ⚠️ 为什么必须排除（2026-10-11 在 zen14 上实测踩到）：
      #   Cilium 的 routingMode=tunnel(vxlan)，它用节点的 **InternalIP** 作为
      #   VXLAN 隧道端点。三个节点的 InternalIP 分属两个网络：
      #       hinihao-sg-prod-net    10.3.0.4       ← VPC 内网
      #       hinihao-sg-prod-world  10.3.4.13      ← VPC 内网
      #       zen14 / nova13         10.144.150.x   ← ET 虚拟 IP
      #   访问 10.3.0.4 时若被 mihomo TUN 劫持（`ip route get` 显示
      #   `via 198.18.0.2 dev Meta`），包会进代理而不是走 ET → 直接丢包。
      #
      #   连锁症状（表面现象与真因相隔很远，容易误判）：
      #     build pod 只能访问**同节点** pod，跨节点全断（Cilium VXLAN 到不了）
      #     → 解析不了 kube-dns(10.112.0.10) → 所有域名解析失败
      #     → registry 访问 COS 超时 → build pod ImagePullBackOff。
      #
      #   ⚠️ 排查时别被 MTU 带偏：cilium_vxlan 的 MTU 看起来很像 MTU 问题
      #   （zen14 上是 1500，而 net/world 是 1360），但实测 ping 大小包
      #   **都不通** —— 根因是上面这条路由，不是 MTU。
      "10.3.0.0/22"
      "10.3.4.0/22"
    ];
  };
}
