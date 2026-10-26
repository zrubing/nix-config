# Build 节点（zen14 / nova13）共用的 mihomo 覆盖配置。
#
# ⚠️ **单一事实源**：两台机器的 `miho-extra-config.nix` 曾经各写一份，结果是
#    nova13 漏了 `127.0.0.2/3`（tcp-forward 转发端口被 mihomo 抢走）和
#    集群节点 VPC 网段（跨节点 Cilium VXLAN 全断）—— 而 zen14 有。
#    「同一语义两处各写一份」正是漂移的温床，故收敛到本文件。
#
# 消费方：systems/x86_64-linux/{zen14,nova13}/default.nix 的
#         `${namespace}.miho.extraConfig = import <本文件>;`
#
# ⚠️ 本文件只放「mihomo 特有的本机偏好」。**不变量不在这里**：
#    · 哪些流量永不进代理（NTP 的 123 端口、ET/集群网段、tcp-forward 的 loopback）
#      → modules/nixos/net-policy（三家客户端共用同一份声明，切 sib 也不会丢）
#    · 为什么是这些值、踩过什么坑        → docs/net-invariants.md
#    miho 模块会把 net-policy 的条目合并进来（rules 前置、地址取并集）。
{
  dns = {
    # resolved 上游配置为 127.0.0.1:53（由 miho 模块声明），基础配置里
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
    # 与 sib 同一个根因：cilium 的 CILIUM_OUTPUT 链把 skb mark 归一化为 0xc00
    # （mark and 0xfffff0ff xor 0xc00），sing-tun 默认的
    # auto-redirect-output-mark = 0x2024 被改成 0x2c24，自身的出站连接随即
    # 被 `not fwmark 0x2024 lookup 2022` 规则塞回 TUN —— 日志里的
    # "dial tcp <节点>: no such device" 就是自环时绑定设备失败。
    # 0x1c00（十进制 7168）命中 cilium 的不改写分支（mark & 0xe00 == 0x800），
    # 改写对它是幂等的；0x1000 是 cilium 未使用的 k8s mark 位，能和普通 host
    # 流量的 0x0c00 区分。
    auto-redirect-output-mark = 7168;
  };
}
