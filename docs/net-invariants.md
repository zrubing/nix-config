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
| 代理入口域名走真实解析 | `dnsDirectDomainTokens`（token，值在密文） | 见「代理入口的两条闸门」 |
| 代理服务器地址不进 TUN | `tunnelExcludeTokens`（token，值在密文） | 同上 |

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

## 代理入口的两条闸门

代理客户端自己也要用域名连出口服务器。这件事和「目标网站怎么解析」是两条独立的
链路，混在一起会出一个很难查的故障：

1. 客户端查出口服务器的域名，而上游 DNS 就是本机代理（fakeip 模式）→ 拿到假地址
2. 客户端连假地址 → 被 TUN 抓回来、反查成域名 → 按 `final` 走代理
3. 于是「客户端到服务器」的握手被塞进了另一条代理链路，永远超时

实测症状：客户端每 500ms 重连一次、节点永久不可用，而 `sing-box check` 和服务
健康检查全部通过。

两条闸门必须同时关，只关一条都不够：

| 闸门 | 声明 | 作用 |
|---|---|---|
| 入口域名真实解析 | `dnsDirectDomainTokens` | 这些域名走真实上游，不被 fakeip 改写 |
| 服务器地址不进 TUN | `tunnelExcludeTokens` | 目标地址在 nfqueue 阶段就被放行 |

- 只关第一条：客户端拿到真实地址后，目标变成 IP 字面量，域名规则匹配不到，
  包照样进 TUN 绕一圈（表现为「首次能连上、握手偶发超时」）
- 只关第二条：应用侧拿到的仍是假地址，语义上还是代理流量，还多绕一层 fakeip 反查

两者都只声明 token，真值在密文里，prepare 阶段展开——公开仓库不能出现这些地址。

### 验收陷阱：别用 nft set 判断

`nft list set inet sing-box inet4_route_exclude_address_set` 的内容对应的是
`route_exclude_address_set`（rule_set 引用），**不是** `route_exclude_address`。
后者加了新地址后，set 里看不到它们，但包在 nfqueue 处理时已被放行、不产生
inbound 日志。

正确验收：看客户端日志里还出不出现这些目标的 `inbound connection`。

## 地址族与协议：候选集，不是动态切换

代理客户端**不会**在连接失败后换地址族或换协议：

- `domain_resolver.strategy` / `ip-version` 只是「优先解析哪一族」，不是失败转移
- 实测：屏蔽某节点的 v4 后 45 秒，QUIC 出站的尝试目标始终是 v4，0 次尝试 v6
- QUIC/UDP 也没有 TCP 那种 Happy Eyeballs（那是 TCP 的连接竞速机制）

想要「v4 挂了走 v6」「UDP 慢了换 TCP」，正确做法是**把不同组合拆成独立出站，
全部塞进 urltest 候选**，让实测延迟决定：

| 出站 | 协议 × 地址族 | 怎么来 |
|---|---|---|
| `节点` | QUIC × v4 | 常规节点定义 |
| `节点-v6` | QUIC × v6 | 节点加可选 `server6` 字段，转换器派生 |
| `节点-tcp-v6` | TCP × v6 | `vless-reality` 类型的独立节点 |

注意 urltest 选的是**最快节点**，不是「同节点的另一条地址族」——v4 节点挂掉时，
只要别的 v4 节点还活着且更快，就不会用到同节点的 v6。要「宁可慢也留在同一台」
得用 `fallback` 出站，语义不同。

## fakeip 的 IPv6 闸门

`fakeipInet6Range` 默认 `null`（关闭），此时 AAAA 查询返回空，应用侧拿不到任何
v6 地址。设成 CIDR 才打开。三个前提：

1. **本机不需要公网 IPv6** —— fakeip 是本地生成的地址，出口在节点那边
2. **段不能用 ULA**（`fc00::/7`）：本模块有 `ip_is_private → 直连` 规则，ULA 会被
   判成内网地址，fakeip 目标可能被误判成直连。用非私有段
3. 打开后 fakeip 的 v6 与 v4 并存，应用会同时拿到两者

打开后**真实连接仍然优先 v4**：`dns.strategy: prefer_ipv4` + direct 出站
`domain_strategy: null` 让「有 A 记录就用 A」。所以 v6 只在两种情况下生效：
目标只有 AAAA，或走的是显式配了 v6 server 的出站。

反面结论：**不要为了提速把全局改成 `prefer_ipv6`** —— 国内 v6 的路由质量普遍
不如 v4，会把国内流量推到差路径上。

## 待办

- `sib-conf` 密文里仍留着 `route_exclude_address` 副本（与 net-policy 重叠）。
  现在靠 `unique` 去重所以无害，但应下掉，只留一处。
- dae 渲染器。前置条件：cilium 的 `bpf.enableTCX=false` 或换方案，见
  `docs/dae-cilium-tcx.md`。在那之前 dae 属于「用不了还养着一套配置」。
