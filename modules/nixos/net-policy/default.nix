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
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.netPolicy;

  mysecrets = inputs.mysecrets;

  # 敏感 CIDR 的占位符。真实地址在 nix-secrets 的 net-policy-addresses.json.age
  # 里，由各客户端的 prepare 阶段展开——原因：nix-config 是公开仓库，而这些
  # 地址（公网中转 VPS、自建 apiserver）一旦写进 nix 就同时泄漏到两处：
  #   · GitHub（永久留痕，抹不掉）
  #   · 0644 的 /nix/store（实测 mihomo-extra.yaml 里 nobody 可读 IP-CIDR 规则）
  #
  # token 名 = __NETPOLICY_<密文键>__，客户端从 token 本身推出要取密文的哪个
  # 键（去首尾包装即可），因此不用在 4 处同步一张映射表。
  # token 不是合法 CIDR，忘展开时 sing-box check / mihomo 都会直接报错，
  # 不存在「带着占位符静默跑」这种失败模式（对比密码占位符那次 419）。
  addressTokens = {
    directCidrs = "__NETPOLICY_directCidrs__";
    cnCidrs = "__NETPOLICY_cnCidrs__";
    directDomains = "__NETPOLICY_directDomains__";
    jpDomains = "__NETPOLICY_jpDomains__";
    usDomains = "__NETPOLICY_usDomains__";
  };

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
    # 2026-10-27 实测：sib 有的 4 条直连例外（两个 xray CDN 入口域名、
    # 两台中转 VPS 的 /32）miho 根本没有 —— 切到 miho 时访问这些目标的流量会
    # 进代理组（回环风险），而两份密文都不可 review、没有 diff 历史。
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
        #
        # 地址与域名都是敏感数据（自有域名、公网中转 VPS、自建 apiserver），
        # 这里只留 token，真值由 prepare 阶段从 net-policy-addresses.json.age
        # 展开（见 let 里的 addressTokens）。
        #
        # 第一条是 xray-client 的 CDN 入口域名（上下行分离用），进代理就会
        # 自指：代理走的又是这个入口。
        {
          match = "domain-suffix";
          value = addressTokens.directDomains;
          target = "直连";
        }
        {
          match = "ip-cidr";
          value = addressTokens.directCidrs;
          target = "直连";
        }

        # 定向网段。地址同样敏感，走 token。
        {
          match = "ip-cidr";
          value = addressTokens.cnCidrs;
          target = "国内";
        }

        # 指定出口。
        #
        # 这里不能写 youtube.com：domain_suffix 会抢在下面的 geosite-youtube 之前
        # 命中，YouTube 组（selector）从此收不到任何主域名流量。实测删之前
        # www.youtube.com / youtube.com / m.youtube.com 全走“美国”，只有 youtu.be
        # 能落到 geosite-youtube。把某站固定到某出口前先确认它没有专属 rule-set，
        # 否则就是用一条宽规则覆盖掉一整组。
        #
        # 公开服务域名可以直接写在 nix 里；自有域名走 token。
        {
          match = "domain-suffix";
          value = [
            "huggingface.co"
            "codeberg.org"
            "grok.com"
            "x.ai"
            "chatgpt.com"
          ] ++ [ addressTokens.usDomains ];
          target = "美国";
        }
        {
          match = "domain-suffix";
          value = addressTokens.jpDomains;
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

    # ── fakeip v6 闸门 ────────────────────────────────────────────────
    #
    # null（默认）= AAAA 查询不返回 fakeip v6 → 应用侧拿不到 v6 地址，全走 IPv4。
    # 这不是「没配」，是有意的取舍：打开后所有代理域名会优先拿 v6 地址、流量从
    # 节点 v6 出站，而分流的 v6 侧完全依赖 geoip-* 规则集是否覆盖 v6 段。
    #
    # 设成 CIDR 才打开。已知前提：
    #   1. 本机不需要公网 IPv6 —— fakeip 是本地生成的地址，出口在节点那边。
    #      只需该段的路由指向 TUN（auto_route 下 sing-box 自己加）。
    #   2. 该段不能被本机真实地址占用（查 `ip -6 addr` 与 `ip -6 route`）。
    #   3. 避开 sing-box 的 `ip_is_private → 直连` 规则：ULA（fc00::/7）有被这条
    #      规则当成内网直连的风险。打开后必须实测「fakeip v6 目标的日志走的是
    #      代理出站而不是 direct」—— 这一条实测过才算真的能用。
    fakeipInet6Range = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      defaultText = lib.literalExpression "null（关闭）";
      description = "fakeip 的 IPv6 段；null 表示应用侧不使用 IPv6。";
    };

    # 敏感地址的占位符与解密后路径。客户端 prepare 用它们把 render 出来
    # 的 token 展开成真实 CIDR。从这里取而不是在客户端里硬编码 token 名，
    # 否则改一个字符串要在 4 处同步。
    addressTokens = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      internal = true;
      readOnly = true;
      default = addressTokens;
      description = "敏感 CIDR 的占位符（键：directCidrs / cnCidrs）。";
    };

    # ── 代理入口：客户端与服务器之间的链路必须绕开代理自己 ────────────
    #
    # 两条不变量，这里只声明 token，真值在 net-policy-addresses.json.age：
    #   · dnsDirectDomainTokens —— 这些域名必须用真实上游解析，不能被 fakeip 改写
    #   · tunnelExcludeTokens   —— 这些地址永不进 TUN，代理客户端连服务器本身直出
    #
    # 为什么两条都要（实测 2026-10-27，tuic-client 连 vps-a）：
    #   客户端用域名连服务器，经系统 DNS(sing-box) 拿到 fakeip 198.18.3.0；连接被
    #   TUN 反查回域名，命中 final 走代理 → QUIC 握手被塞进另一个代理的 UDP 通道
    #   → 每 500ms 重连一次，节点永久不可用。
    #
    #   只修 DNS 不够：客户端也可能拿到真实地址（resolved 缓存），那时目标是 IP
    #   字面量，域名规则匹配不到，包照样进 TUN 绕一圈（表现为「首次连上、握手偶发
    #   超时」）。实测 tuic-client-jp 就是这样。
    #   只修 TUN 排除也不够：应用侧拿到的仍是 fakeip，语义上依然是代理流量，且
    #   fakeip 反查会多绕一层 netfilter。
    #
    # 两条闸门同时关死，客户端与服务器之间才是一条干净的直连链路。
    dnsDirectDomainTokens = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      internal = true;
      readOnly = true;
      default = [ addressTokens.directDomains ];
      description = "必须真实解析的域名（token，prepare 阶段展开）。";
    };

    tunnelExcludeTokens = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      internal = true;
      readOnly = true;
      default = [ addressTokens.directCidrs ];
      description = "永不进 TUN 的地址（token，prepare 阶段展开）。";
    };

    addressTokenFile = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      default = config.age.secrets."net-policy-addresses".path;
      description = "net-policy-addresses 解密后的路径（含 directCidrs / cnCidrs）。";
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
    # 敏感地址表。声明在这里而不是在两个客户端里，是因为 sib 与 miho 要读
    # 同一份文件 —— 各声明一次会撞同名 secret 选项。
    age.secrets."net-policy-addresses" = {
      file = "${mysecrets}/net-policy-addresses.json.age";
    };

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
