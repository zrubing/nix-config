# 代理不变量（net-policy）

「不管用哪个代理客户端（miho / sib / dae）都必须成立」的那些规则。事实源在
`modules/nixos/net-policy`：那里只声明**要什么**，每个客户端模块自己渲染成
自己的语法。

## 为什么要有这个文件

本机三种客户端 schema 完全不同，而这些规则过去在每家的配置里各写一份，
其中两份在 age 密文里（不可 review、无 diff、CI 看不见）。结果是**已经漂了**：
2026-10-26 实测 zen14 上 sib 的 `route_exclude_address` 有 9 条、miho 只有 7 条，
NTP 直连规则只有 miho 有。靠纪律对齐三份配置不现实，只能靠单一事实源。

## 清单

| 不变量 | 值 | 为什么 |
|---|---|---|
| 校时端口直连 | `bypassProxyPorts = [ 123 ]` | NTP 走代理 → 时钟准不准取决于代理节点。2026-10-26 nova13 因此偏 45 分钟（开机 27 小时零次成功 step），还差点把当天的事故复盘带偏 |
| 集群/overlay 网段不进代理 | `bypassProxyCidrs`（ET overlay、两套 VPC 子网、cilium overlay、老集群 CIDR） | 这些包被 TUN 劫持后症状离真因极远：ET 把自己的虚拟地址当 P2P 候选广播 → 自指链路 → 100% 丢包；cilium vxlan 端点进代理 → 跨节点 pod 全断 → 解析不了 kube-dns → build pod `ImagePullBackOff` |
| tcp-forward 的 loopback 不进代理 | `bypassProxyLoopback = [ 127.0.0.2/32 127.0.0.3/32 ]` | 不排除 → 本机连不上自己的转发端口（test-mysql / prod-mysql） |

具体值见 `modules/nixos/net-policy/default.nix`（不在文档里重复，避免第二份真相）。

## 各客户端的渲染状态

| 客户端 | `rules` 前置 | 地址排除 | 备注 |
|---|---|---|---|
| miho (mihomo) | ✓ `rules` + `DST-PORT,<p>,DIRECT` | ✓ `tun.route-exclude-address`（与 extraConfig 取并集） | 见 `modules/nixos/miho` |
| sib (sing-box) | ✓ `route.rules` 前插 `{port=[…], outbound="直连"}` | ✓ `inbounds[tun].route_exclude_address`（与密文取并集 + `unique`） | 见 `modules/nixos/sib` 的 prepare 脚本 |
| dae (eBPF) | ✗ | ✗ | **未接入**，启用时会打 `warnings`。前置条件见 `docs/dae-cilium-tcx.md`（dae 与 cilium 的 tcx 冲突） |

## 验证

```bash
# 生成期：三个客户端各自的配置自检（sib 用 sing-box check；miho 用 mihomo -t）
systemctl status net-policy-check     # 运行时核对：生效的配置里确实有这些条目
journalctl -u net-policy-check -n 20

# 手工抽查（结果导向，比断言文本更硬）
ip route get 8.8.8.8                  # 出现 dev Meta / singtun 说明在走代理
timedatectl timesync-status           # Delay 应为几十毫秒、server 为境内
```

`net-policy-check` 抓的是「合并脚本静默失效」——例如 jq/yq 程序写错导致
合并变成 no-op、或上游配置换了字段名。它核对的是**跑起来的配置文件**，不是 nix 表达式。

## 变更流程

1. 改 `modules/nixos/net-policy`（唯一的改动点）。
2. `nixos-rebuild switch`。两个客户端的 `restartTriggers` 都带了 policy 产物，
   不写这条会出现「改了 nix 但行为没变」。
3. `systemctl start net-policy-check` 确认通过。
4. ⚠️ **不要再往 age 密文里加同样的条目** —— 那正是漂移的来源。密文只放
   节点、凭据、域名/geoip 规则这类「会变且不需要 review」的东西。

## 待办

- `sib-conf` 密文里仍留着 `route_exclude_address` 副本（与 net-policy 重叠）。
  现在靠 `unique` 去重所以无害，但应下掉，只留一处。
- dae 渲染器。前置条件：cilium 的 `bpf.enableTCX=false` 或换方案，见
  `docs/dae-cilium-tcx.md`。在那之前 dae 属于「用不了还养着一套配置」。
