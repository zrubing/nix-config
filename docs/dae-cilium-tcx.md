# dae 与 cilium 的 tcx/clsact 冲突（2026-10）

## 结论

zen14 上 **dae 无法工作**：cilium 用 tcx 挂载 host 网卡程序后，内核对同一张网卡的
clsact 标记为独占，dae 的 tc filter 能挂上但永远不会执行。因此 2026-10 切回 sib，
dae 模块保留、开关关闭。

## 现象

1. `dae.service` active，日志有 `Bind to WAN: wlp1s0`，配置校验通过。
2. 所有流量直连：`ipinfo.io` 返回本地 IP，墙外站点（google/youtube/twitter）全部超时。
3. `dae0` 的 tx/rx 计数一直不动（无流量被重定向进 dae 数据面）。
4. `routing { fallback: block }` 也不生效——说明连兜底都不在路径里，不是配置问题。
5. DNS 仍是污染答案（`www.google.com` → `157.240.7.20` / `2001::1`），dae 没截到 :53。

## 定位过程（关键实验）

1. `bpftool prog show`：`tproxy_wan_egress` 的 `run_cnt` 恒为 0；
   `tproxy_dae0_ingress` 有 15 次；cgroup 系列（`tproxy_wan_cg_connect4` 等）正常增长，
   `cookie_pid_map` 里有 xray/dae 条目 → dae 加载链路没问题，只有 tc hook 不跑。
2. 自写一个 `return TC_ACT_SHOT` 的 tc 程序（`drop.o`）挂到 wlp1s0 egress clsact：
   `curl baidu` 仍然 200，`run_cnt` 为 0。
3. 同一程序挂 veth egress：`run_cnt 17`，ping 100% 丢包；挂 dummy0：`run_cnt 5`。
   → 程序本身和挂载方式都没问题，问题在 wlp1s0 这张网卡。
4. 在临时 dummy 网卡（dum2）上复现：cilium 自动挂上 `cil_to_netdev`（tcx_egress）时，
   clsact 的 `drop_all` 的 `run_cnt` 为 0；用 `bpftool link detach` 摘掉 cilium 的
   tcx_egress 后，同一个程序立刻 `run_cnt 3`。
5. 往已有 cilium tcx 的设备加 clsact 会报：
   `Error: Exclusivity flag on, cannot modify.`

## 根因

1. 每张网卡只有一个 ingress/clsact qdisc（`TCQ_F_INGRESS` 静态标志），它持有
   `dev->miniq_ingress` / `dev->miniq_egress`，tc filter 通过这对指针进数据路径。
2. tcx 是这套机制的新前端：挂 tcx 程序时，内核在网卡上创建一个**带 exclusivity
   标志的 clsact**，miniq 的引用计数归 tcx entry 所有（`tcx_miniq_inc`）。
3. legacy `tc filter` 可以写进 block，但 block 不在 tcx 的 mprog 链里 → 数据包不经过它。
4. 内核这么设计是为了避免 clsact 与 tcx 各自维护 miniq 导致的并发 UAF，见：
   - Peilin Ye 2023 补丁系列（clsact/ingress 唯一性、miniq 指针竞争）：
     https://patchew.org/linux/cover.1684796705.git.peilin.ye@bytedance.com/mbox
   - Daniel Borkmann 2026（clsact 与 tcx 共用 refcount）：
     https://lore.kernel.org/netdev/20260313065531.98639-1-daniel@iogearbox.net/

所以这不是配置能绕过去的：**只要 cilium 在这张网卡上用 tcx，dae 的 clsact 就是死的**。

环境：kernel `7.3.0-cachyos`，网卡 `wlp1s0`（mt7921e，非根因），
cilium 以 tcx 挂 `cil_from_netdev` / `cil_to_netdev`。

## 以后要启用 dae 的前置条件

### 方案 A（优先试）：cilium 退回 legacy tc

cilium 有 helm value `bpf.enableTCX`（默认 `true`）。设为 `false` 即退回 legacy tc，
cilium 与 dae 的 filter 回到同一个 clsact block，按 pref 排序：

```
helm upgrade cilium cilium/cilium -n kube-system --reuse-values --set bpf.enableTCX=false
```

注意：

1. `bpf.datapathMode=netkit` 时 cilium 强制 `enableTCX=true`（`pkg/datapath/connector/config.go`），
   只有 veth 模式能关。
2. 验证：`bpftool net show dev wlp1s0` 不再有 tcx；`tc filter show dev wlp1s0 egress`
   同时能看到 cilium 与 dae 的 filter。
3. 仍需实测 cilium 程序返回 `TC_ACT_OK` 是否会截断后面的 filter：dae 用 pref 2，
   cilium legacy 用 `HANDLE_MIN_EGRESS`(3)，理论上 dae 先跑；跑不通就再调 pref。

### 方案 B：cilium 不接管 wlp1s0

`--devices` 支持排除语法。代价是这张网卡上没有 cilium 的 masquerade/policy，
该节点 pod 出网可能受影响（取决于 masquerade 模式）。

### 方案 C：换内核

6.12 LTS 那条线早于这批 clsact/tcx 独占语义，行为可能不同。

## 切回 dae 的步骤

1. 先按方案 A/B/C 处理 cilium，并确认 `drop_all` 类测试在 wlp1s0 上生效。
2. `systems/x86_64-linux/zen14/default.nix`：`sib.enable = false; dae.enable = true;`
3. `modules/home/sops/default.nix` 的 `dsh.env`：删掉 `HTTP_PROXY` / `HTTPS_PROXY`
   （dae 透明代理、DNS 返回真实 IP，也没有本地代理端口）。
4. `sudo nixos-rebuild switch --flake .#zen14`，然后验证：
   - `resolvectl query github.com` 返回真实公网 IP，不再是 `198.18.x`；
   - `systemctl status dae` active，`ip -br link` 有 `dae0`；
   - `curl -4 https://www.google.com` 能通；
   - `dae0` 的 tx/rx 计数随流量增长；
   - 重启 dsh-web 后 `web_fetch` 正常（不再报 non-public IP）。
5. 回滚：开关翻回 sib + 恢复两行 `HTTP_PROXY/HTTPS_PROXY`，再 switch。

## 相关位置

1. `modules/nixos/dae/default.nix` —— dae 模块与断言（与 miho/sib 互斥）。
2. `modules/nixos/sib/default.nix` —— 当前启用的 sing-box（TUN，和 cilium 无冲突）。
3. `modules/home/sops/default.nix` —— `dsh.env` 里的代理变量（dae 与 sib 的差异点）。
4. `systems/x86_64-linux/zen14/default.nix` —— 三选一开关。
