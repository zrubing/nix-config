# 代理**不变量**的单一事实源（single source of truth）。
#
# ── 为什么需要这个模块 ────────────────────────────────────────────────
#
# 本机有三种互斥的代理客户端（miho=mihomo / sib=sing-box / dae=eBPF），
# schema 各不相同。而「不管用哪个客户端都必须成立」的规则，过去是在每个
# 客户端的配置里各写一份：miho 的写在 nix（miho/build-node-extra-config.nix），
# sib / dae 的写在 age 密文里。
#
# 结果不是「可能会漂」，而是**已经漂了**（2026-10-26 实测 zen14）：
#   · route-exclude 地址：sib 有 9 条，miho 只有 7 条 —— miho 缺
#     10.3.12.0/22（world 节点 VPC 子网）和 10.246.0.0/16（cilium overlay）；
#   · NTP 直连规则：miho 有，sib 没有。
# 而且密文里那两份既不能 review、也没有 diff 历史，靠人记不可能对齐。
#
# ── 本模块只声明「要什么」 ────────────────────────────────────────────
#
# 各客户端模块自己渲染成自己的语法（本模块不碰任何客户端选项）：
#   · miho → extraConfig 的 `rules` / `tun.route-exclude-address`
#   · sib  → `route.rules` 前插 / `inbounds[tun].route_exclude_address`
#   · dae  → **未接入**，见 modules/nixos/dae 顶部注释（该客户端当前不可用）
#
# 切换客户端时不需要搬运任何东西：不变量根本不在客户端配置里。
#
# 运行时还有 net-policy-check.service 核对「真正生效的配置里确实有这些条目」
# —— 验结果，不验文本：它能抓住「合并脚本静默失效」这类最难发现的问题。
{
  config,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.netPolicy;

  # 去重后的一份完整地址表：loopback 与网段之间可能重复（当前没有，但不该靠人保证）。
  allAddresses = lib.unique (cfg.bypassProxyLoopback ++ cfg.bypassProxyCidrs);

  # 期望值快照：给运行时自检用（避免脚本里再抄一遍常量）。
  expectedJson = (pkgs.formats.json { }).generate "net-policy-expected.json" {
    ports = map toString cfg.bypassProxyPorts;
    inherit (cfg) bypassProxyAddresses;
  };

  mihoEnabled = config.${namespace}.miho.enable or false;
  sibEnabled = config.${namespace}.sib.enable or false;

  # 只有一条「生效中的客户端」需要核对；两个都没开（例如临时停机维护）就不建这个单元。
  clientCheck =
    if mihoEnabled then
      {
        unit = "mihomo.service";
        script = ''
          set -euo pipefail
          cfg=/run/mihomo/config.yaml
          [ -s "$cfg" ] || { echo "net-policy: $cfg 不存在（mihomo 还没生成配置？）" >&2; exit 1; }

          # 期望值文件必须存在：否则下面的 for 循环会拿到空列表、直接"通过"，
          # 变成静默假绿（实测踩过：jq 报错但脚本 exit 0）。
          exp=${expectedJson}
          [ -s "$exp" ] || { echo "net-policy: 期望值文件 $exp 不存在" >&2; exit 1; }
          ports="$(jq -r '.ports[]' "$exp")"
          addrs="$(jq -r '.bypassProxyAddresses[]' "$exp")"

          rules="$(yq -o=json -I=0 '.rules' "$cfg")"
          excl="$(yq -o=json -I=0 '.tun.route-exclude-address' "$cfg")"

          bad=0
          for p in $ports; do
            jq -e --arg r "DST-PORT,$p,DIRECT" 'index($r) != null' <<<"$rules" >/dev/null \
              || { echo "net-policy: miho 缺分流规则 DST-PORT,$p,DIRECT" >&2; bad=1; }
          done
          for a in $addrs; do
            jq -e --arg a "$a" 'index($a) != null' <<<"$excl" >/dev/null \
              || { echo "net-policy: miho 的 tun.route-exclude-address 缺 $a" >&2; bad=1; }
          done
          exit $bad
        '';
      }
    else if sibEnabled then
      {
        unit = "sib.service";
        script = ''
          set -euo pipefail
          cfg=/run/sib/config.json
          [ -s "$cfg" ] || { echo "net-policy: $cfg 不存在（sib 还没生成配置？）" >&2; exit 1; }

          exp=${expectedJson}
          [ -s "$exp" ] || { echo "net-policy: 期望值文件 $exp 不存在" >&2; exit 1; }
          ports="$(jq -r '.ports[]' "$exp")"
          addrs="$(jq -r '.bypassProxyAddresses[]' "$exp")"

          bad=0
          for p in $ports; do
            jq -e --argjson p "$p" '
              [ .route.rules[]
                | select(.port != null)
                | select((.port | if type == "array" then . else [ . ] end) | index($p))
                | select((.outbound // "") == "直连" or (.action // "") == "direct")
              ] | length > 0' "$cfg" >/dev/null \
              || { echo "net-policy: sib 缺 port $p 的直连规则" >&2; bad=1; }
          done
          for a in $addrs; do
            jq -e --arg a "$a" '
              [ .inbounds[] | select(.type == "tun") | (.route_exclude_address // [])[] ]
              | index($a) != null' "$cfg" >/dev/null \
              || { echo "net-policy: sib 的 tun.route_exclude_address 缺 $a" >&2; bad=1; }
          done
          exit $bad
        '';
      }
    else
      null;
in
{
  options.${namespace}.netPolicy = {
    bypassProxyPorts = lib.mkOption {
      type = with lib.types; listOf port;
      default = [ 123 ];
      description = ''
        目标端口命中这些值的流量**永不进代理**。

        当前只有 123（NTP）：校时一旦经代理出境，就变成「时钟准不准取决于代理
        节点是否活着」。2026-10-26 实测 nova13 因此偏了 45 分钟（开机 27 小时
        没有一次成功 step），并让当天的事故复盘差点被日志时间戳带偏。
      '';
    };

    bypassProxyCidrs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [
        # 这些包如果被 TUN 劫持，症状离真因很远（历史上都踩过）：
        #   · ET 把自己的虚拟地址当 P2P 候选广播 → 自指链路 → 100% 丢包
        #   · cilium vxlan 端点（节点 InternalIP）进代理 → 跨节点 pod 全断
        #     → 解析不了 kube-dns → build pod ImagePullBackOff
        "10.144.0.0/16" # EasyTier overlay
        "10.3.0.0/22" # acme-prod-net VPC
        "10.3.4.0/22" # acme-prod-world VPC
        "10.3.12.0/22" # world 节点 VPC 子网
        "10.246.0.0/16" # cilium overlay（cilium_host / cilium_health 地址）
        "10.96.0.0/12" # 老集群 serviceCIDR（已失效，留着让迁移痕迹可见）
        "10.244.0.0/16" # 老集群 podCIDR（同上）
      ];
      description = "这些目标网段永不进代理 —— 由本机路由表负责送达。";
    };

    bypassProxyLoopback = lib.mkOption {
      type = with lib.types; listOf str;
      default = [
        "127.0.0.2/32"
        "127.0.0.3/32"
      ];
      description = ''
        tcp-forward 的 loopback 监听地址（test-mysql@127.0.0.2、prod-mysql@127.0.0.3）。
        不排除 → 本机连不上自己的转发端口。
      '';
    };

    bypassProxyAddresses = lib.mkOption {
      type = with lib.types; listOf str;
      internal = true;
      readOnly = true;
      default = allAddresses;
      description = "loopback + 网段去重后的完整地址表，供各客户端渲染器使用。";
    };
  };

  config = lib.mkIf (clientCheck != null) {
    systemd.services.net-policy-check = {
      description = "Verify proxy bypass invariants against the live client config";
      wantedBy = [ "multi-user.target" ];
      # wants/after 而不是 requires：客户端起不来时不连累这个单元变红，
      # 它自己会因为配置文件不存在而失败（错误信息更直接）。
      wants = [ clientCheck.unit ];
      after = [ clientCheck.unit ];
      path = with pkgs; [
        coreutils
        jq
        yq-go
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = clientCheck.script;
    };
  };
}
