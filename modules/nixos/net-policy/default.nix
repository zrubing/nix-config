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
# 各客户端模块自己把声明渲染成自己的语法。本模块不写客户端的配置文件，
# 但确实会**读**两个客户端导出的路径（sib.configPath / services.mihomo.configFile）
# 做运行时自检 —— 否则同一个文件名要在两处各写一份，重命名时会静默漂开
# （实测踩过：自检报「配置不存在」，真实原因只是文件名叫法不同）。
# 除了这两个只读路径，不引用任何客户端的其他选项。
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

  # ── 分流规则的方言渲染 ────────────────────────────────────────────
  # 规则本身只声明「匹配什么 → 走哪个出站 tag」，两家客户端各自方言在这里生成：
  #   sib  → route.rules 的对象数组（ip_cidr / domain_suffix / ip_is_private / rule_set）
  #   miho → "TYPE,value,target[,no-resolve]" 字符串数组
  # 规则集名字两边不同（geosite-x/geoip-x 与 x_domain/x_ip），映射也在这里，
  # 调用方不需要知道任何一家的拼写。
  asList = v: if builtins.isList v then v else [ v ];

  # 不写 no-resolve 时：IP 类规则默认加（域名连接不必为了判 IP 先解析一次）。
  wantsNoResolve =
    r: if r.noResolve == null then (r.match == "ip-cidr") else r.noResolve;

  sibRule =
    r:
    if r.match == "ip-cidr" then
      {
        ip_cidr = asList r.value;
        outbound = r.target;
      }
    else if r.match == "domain-suffix" then
      {
        domain_suffix = asList r.value;
        outbound = r.target;
      }
    else if r.match == "private" then
      {
        ip_is_private = true;
        outbound = r.target;
      }
    else if r.match == "rule-set" then
      {
        rule_set = [ (if r.kind == "ip" then "geoip-${r.set}" else "geosite-${r.set}") ];
        outbound = r.target;
      }
    else
      throw "net-policy: 未知 match ${r.match}";

  # miho 一个语义条目可能展开成多条（每个 CIDR / 域名一条字符串）。
  mihoRule =
    r:
    if r.match == "ip-cidr" then
      map (
        c: "IP-CIDR,${c},${r.target}${lib.optionalString (wantsNoResolve r) ",no-resolve"}"
      ) (asList r.value)
    else if r.match == "domain-suffix" then
      map (d: "DOMAIN-SUFFIX,${d},${r.target}") (asList r.value)
    else if r.match == "private" then
      [ "RULE-SET,private_ip,${r.target},no-resolve" ]
    else if r.match == "rule-set" then
      [
        "RULE-SET,${
          if r.mihoSet != "" then
            r.mihoSet
          else if r.kind == "ip" then
            "${r.set}_ip"
          else
            "${r.set}_domain"
        },${r.target}"
      ]
    else
      throw "net-policy: 未知 match ${r.match}";

  # 只有一条「生效中的客户端」需要核对；两个都没开（例如临时停机维护）就不建这个单元。
  clientCheck =
    if mihoEnabled then
      {
        unit = "mihomo.service";
        script = ''
          set -euo pipefail

          cfg=${config.services.mihomo.configFile}
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
            jq -e --arg r "DST-PORT,$p,直连" 'index($r) != null' <<<"$rules" >/dev/null \
              || { echo "net-policy: miho 缺分流规则 DST-PORT,$p,直连" >&2; bad=1; }
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

          cfg=${config.${namespace}.sib.configPath}
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

    # ── 分流规则的单一事实源 ──────────────────────────────────────
    #
    # 过去这份主干在两个客户端的 age 密文里各写一份（sib 25 条 / miho 29 条）。
    # 2026-10-27 实测：sib 有的 4 条直连例外（__NETPOLICY_directDomains__、__NETPOLICY_directDomains__、
    # __NETPOLICY_directCidrs__、__NETPOLICY_directCidrs__）miho 根本没有 —— 切到 miho 时访问这些
    # 目标的流量会进代理组（回环风险），而两份密文都不可 review、没有 diff 历史。
    #
    # 这里只声明「匹配什么 → 走哪个出站 tag」，顺序即优先级；客户端方言由
    # sibRules / mihoRules 两个只读选项渲染。密文里不应再手写分流规则。
    rules = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            match = lib.mkOption {
              type = lib.types.enum [
                "ip-cidr"
                "domain-suffix"
                "private"
                "rule-set"
              ];
              description = "匹配类型；private = 内网地址（两家各有原生写法）。";
            };
            value = lib.mkOption {
              type = lib.types.either lib.types.str (lib.types.listOf lib.types.str);
              default = "";
              description = "ip-cidr 的 CIDR / domain-suffix 的域名；rule-set 时留空。";
            };
            set = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "rule-set 的语义名（如 github、cn），各家拼法由渲染器补全。";
            };
            kind = lib.mkOption {
              type = lib.types.enum [
                "domain"
                "ip"
                ""
              ];
              default = "";
              description = "rule-set 属于域名类还是 IP 类。";
            };
            mihoSet = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "miho 侧 provider 名与命名规则不一致时在这里覆盖（如 geolocation-!cn）。";
            };
            target = lib.mkOption {
              type = lib.types.str;
              description = "出站 tag，必须与客户端配置里的 outbound / 策略组名一致。";
            };
            noResolve = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = "null = IP 类规则自动加 no-resolve；其他类型默认不加。";
            };
          };
        }
      );
      default = [
        # 直连例外：访问这些目标绝不能进代理，否则自指回环。
        {
          match = "domain-suffix";
          value = [
            "__NETPOLICY_directDomains__"
            "__NETPOLICY_directDomains__"
          ];
          target = "直连";
        }
        {
          match = "ip-cidr";
          value = [
            "__NETPOLICY_directCidrs__"
            "__NETPOLICY_directCidrs__"
          ];
          target = "直连";
        }

        # 定向网段。
        {
          match = "ip-cidr";
          value = "__NETPOLICY_cnCidrs__";
          target = "国内";
        }

        # 指定出口。
        {
          match = "domain-suffix";
          value = [
            "__NETPOLICY_usDomains__"
            "youtube.com"
            "huggingface.co"
            "codeberg.org"
            "grok.com"
            "x.ai"
            "chatgpt.com"
          ];
          target = "美国";
        }
        {
          match = "domain-suffix";
          value = "__NETPOLICY_jpDomains__";
          target = "日本";
        }

        # 内网一律直连（必须排在所有域名规则集之前，否则内网域名会被 rule-set 抢走）。
        {
          match = "private";
          target = "直连";
        }

        # 域名规则集：顺序即优先级。
        {
          match = "rule-set";
          set = "github";
          kind = "domain";
          target = "Github";
        }
        {
          match = "rule-set";
          set = "twitter";
          kind = "domain";
          target = "Twitter";
        }
        {
          match = "rule-set";
          set = "youtube";
          kind = "domain";
          target = "YouTube";
        }
        {
          match = "rule-set";
          set = "google";
          kind = "domain";
          target = "Google";
        }
        {
          match = "rule-set";
          set = "telegram";
          kind = "domain";
          target = "Telegram";
        }
        {
          match = "rule-set";
          set = "netflix";
          kind = "domain";
          target = "NETFLIX";
        }
        {
          match = "rule-set";
          set = "bilibili";
          kind = "domain";
          target = "哔哩哔哩";
        }
        {
          match = "rule-set";
          set = "bahamut";
          kind = "domain";
          target = "巴哈姆特";
        }
        {
          match = "rule-set";
          set = "spotify";
          kind = "domain";
          target = "Spotify";
        }
        {
          match = "rule-set";
          set = "cn";
          kind = "domain";
          target = "国内";
        }
        # 非中国域名 → 代理。注意它排在 cn 域名之后、cn IP 之前：域名优先于 IP，
        # 所以「不在 geosite-cn 里的国内小站」会被送进代理，这是有意的取舍。
        {
          match = "rule-set";
          set = "geolocation-!cn";
          kind = "domain";
          mihoSet = "geolocation-!cn";
          target = "其他";
        }

        # IP 规则集。
        {
          match = "rule-set";
          set = "google";
          kind = "ip";
          target = "Google";
        }
        {
          match = "rule-set";
          set = "netflix";
          kind = "ip";
          target = "NETFLIX";
        }
        {
          match = "rule-set";
          set = "telegram";
          kind = "ip";
          target = "Telegram";
        }
        {
          match = "rule-set";
          set = "twitter";
          kind = "ip";
          target = "Twitter";
        }
        {
          match = "rule-set";
          set = "cn";
          kind = "ip";
          target = "国内";
        }
      ];
      description = ''
        分流规则主干（单一事实源）。顺序即优先级；只写语义，方言由模块渲染。
        改这里会同时影响 sib 与 miho，两边不可能再漂。
      '';
    };

    final = lib.mkOption {
      type = lib.types.str;
      default = "其他";
      description = ''
        兜底出站 tag。sib 落到 route.final，miho 由模块在**最后**补一条 MATCH
        （不在 mihoRules 里输出 —— 否则 extraConfig 追加的规则会落在 MATCH 之后，
        永远匹配不到）。
        放在这里而不是密文里：兜底策略是「不管用哪个客户端都必须成立」的不变量。
      '';
    };

    # 渲染产物：客户端模块直接用，不再自己拼规则。
    sibRules = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      internal = true;
      readOnly = true;
      default = [
        {
          port = cfg.bypassProxyPorts;
          outbound = "直连";
        }
      ] ++ map sibRule cfg.rules;
      description = "sing-box 方言的 route.rules（含 bypassProxyPorts 的直连规则）。";
    };

    mihoRules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      internal = true;
      readOnly = true;
      default = map (p: "DST-PORT,${toString p},直连") cfg.bypassProxyPorts
        ++ lib.concatMap mihoRule cfg.rules;
      description = ''
        mihomo 方言的 rules 字符串数组（含 bypassProxyPorts 的直连规则）。
        不包含兜底 MATCH —— 它必须由消费方拼在最后一条，见 final 的说明。
      '';
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
