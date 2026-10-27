# sing-box 客户端（代号 sib）。
#
# 与 miho 模块并存：两个模块都在，主机配置里二选一启用。
# 同时启用会在 eval 阶段被断言拦下（两者都要抢 TUN、127.0.0.1:53 和 nftables 规则）。
#
# 配置来源：nix-secrets 里的加密 JSON（sib-conf/<host>.json.age），
# 里面 hy2 密码是 __RELAY_HYSTERIA_PASSWORD__ 占位符；真值在激活时从
# relay/hysteria-password 注入，轮换密码不用重加密整份配置。
#
# 为什么不直接用 nixpkgs 的 services.sing-box：那个模块以普通用户运行，
# 不配 TUN 所需的能力，也不支持「密文配置 + 占位符注入」这条路径。
{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.sib;
  mysecrets = inputs.mysecrets;

  # 主 nixpkgs（nixos-26.05）里的 sing-box 落后一个大版本（1.13.x），
  # 而配置已按 1.14 写（无 independent_cache 等废弃项），所以从 unstable 取。
  # 等主 nixpkgs 跟上就把这里换回 pkgs.sing-box。
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
  };

  # nixpkgs（unstable 与 master 都是）还停在 1.14.3；1.14.4 是 2026-10-24 的纯修复版。
  # 就地覆盖版本，等 nixpkgs 跟进后删掉本段、package 回退到 pkgs-unstable.sing-box。
  # 上游 go.mod 只换了依赖版本，cronet-go 仍是 v0.0.0-20260912104727，
  # 所以 nixpkgs 的 cronet-go 与其补丁（包内 postConfigure 引用的 cronet-go.patch）可原样复用。
  sing-box = pkgs-unstable.sing-box.overrideAttrs (old: {
    version = "1.14.4";
    src = pkgs-unstable.fetchFromGitHub {
      owner = "SagerNet";
      repo = "sing-box";
      tag = "v1.14.4";
      hash = "sha256-1tP0gXUTLGVR32c11nypsZSx2FtBOmKMTJkt+7j/fJU=";
    };
    vendorHash = "sha256-xZWWzvyTrbaxqHG1UdKOVLOd5dPf9z6JfPJf3WeTm5Y=";
  });

  runtimeDir = "/run/sib";
  configPath = "${runtimeDir}/config-with-secret.json";
  # 临时文件必须以 .json 结尾：xray 那次踩过后缀坑，这里统一带上。
  tmpConfigPath = "${runtimeDir}/config-with-secret.next.json";

  secretPath = config.age.secrets."sib-conf".path;
  hy2PasswordPath = config.age.secrets."relay/hysteria-password".path;

  # ── 不变量渲染器（单一事实源：modules/nixos/net-policy）────────────────
  #
  # 密文里只该放「节点 / 凭据 / 域名规则」；「哪些流量永不进代理」是 nix 侧的
  # 声明，这里渲染成 sing-box 的语法再合并进去：
  #   · bypassProxyPorts  → route.rules 前插 { port = [...], outbound = "直连" }
  #     （rule 表按顺序匹配，必须排在 geosite/geoip 规则之前；放在最前是安全的，
  #      因为它只按端口匹配，不依赖协议嗅探结果）
  #   · bypassProxyAddresses → inbounds[tun].route_exclude_address 取并集
  #
  # 为什么不是写死在密文里：那两份配置既不能 review 也没有 diff 历史，实测
  # 已经和 miho 漂了（2026-10-26：sib 9 条 / miho 7 条，且 NTP 规则只有 miho 有）。
  netPolicy = config.${namespace}.netPolicy;
  policyJson = (pkgs.formats.json { }).generate "sib-policy.json" {
    # 分流规则主干由 net-policy 声明（单一事实源），这里是 sing-box 方言的渲染结果。
    # 密文里不再写分流规则；两边客户端的规则不可能再漂。
    rules = netPolicy.sibRules;
    final = netPolicy.final;
    addresses = netPolicy.bypassProxyAddresses;
    # 代理入口的两条不变量（token，prepare 阶段从密文展开）：
    #   dnsDirect       —— 这些域名走 dns-direct，拿真实地址而不是 fakeip
    #   tunnelExclude   —— 这些地址不进 TUN，客户端连服务器本身直接出去
    dnsDirect = netPolicy.dnsDirectDomainTokens;
    tunnelExclude = netPolicy.tunnelExcludeTokens;
    # null = 关闭：不注入 inet6_range，AAAA 查询仍然 NODATA。
    fakeip6 = netPolicy.fakeipInet6Range;
    # 旁路 socks 端口：固定出站、不看 rules。null = 不开监听。
    forcedProxy =
      if netPolicy.forcedProxySocksPort == null then
        null
      else
        {
          port = netPolicy.forcedProxySocksPort;
          tag = "forced-proxy-in";
          outbound = netPolicy.forcedProxyOutbound;
        };
  };

  # 共享节点清单（私有仓的加密 JSON）是唯一事实源。节点定义刻意不经 nix 求值：
  # 一旦渲染成 store 文件，server/跳端口/密码/SNI 就是世界可读的 /nix/store 明文。
  # 进 store 的只有方言转换器 lib/proxy-nodes.jq，prepare 服务在运行时
  # 解密 → 转换 → 合并。
  proxyNodesSecretPath = config.age.secrets."proxy-nodes".path;
  proxyNodesJq = ../../../lib/proxy-nodes.jq;

  # 敏感地址表（自有域名 / 中转 VPS / 自建 apiserver 的 CIDR）。
  # net-policy 的 rules 里只留 __NETPOLICY_<键>__ token，真值在这里。
  netPolicyAddressPath = config.${namespace}.netPolicy.addressTokenFile;

  prepareConfigScript = pkgs.writeShellScript "sib-prepare-config" ''
    set -euo pipefail

    install -d -m 0700 ${runtimeDir}

    # agenix 在 activation 阶段解密，服务启动时可能还没落盘。
    for f in ${secretPath} ${hy2PasswordPath} ${proxyNodesSecretPath} ${netPolicyAddressPath}; do
      i=0
      while [ ! -s "$f" ]; do
        i=$((i + 1))
        if [ "$i" -ge 60 ]; then
          echo "$f 在 60s 内没有出现" >&2
          exit 1
        fi
        sleep 1
      done
    done

    # 这里只做拷贝。占位符留到最终配置生成之后再替换 —— 见下面「注入密码」。
    # 节点是从 proxy-nodes 密文注入的，它们的 password 也写同一个占位符，
    # 只在 base 上替换会漏掉。
    cp ${secretPath} ${runtimeDir}/config.base.json

    # ── 合并共享节点清单（nix-secrets/proxy-nodes.json.age）──────────────
    # 节点定义只写一处（那份加密 JSON）：这里按 sib 方言转换后追加进配置，
    # 并按 sibGroups 给 selector/urltest 补成员。dedupe 保持原顺序 ——
    # selector 的默认项就是列表第一个，不能用 unique（会排序，默认节点被改掉）。
    #
    # 转换器（lib/proxy-nodes.jq）一次产出 sib / sibGroups / miho 三份视图，
    # 两家客户端共用同一份事实源，只在这里各取所需。
    jq -f ${proxyNodesJq} ${proxyNodesSecretPath} > ${runtimeDir}/nodes.json
    jq --slurpfile p ${runtimeDir}/nodes.json '
      ($p[0].sib) as $nodes
      | ($p[0].sibGroups) as $groups
      | .outbounds |= map(
        . as $o
        | if ($groups | has($o.tag)) then
            .outbounds = (((.outbounds // []) + ($groups[$o.tag] - (.outbounds // []))))
          else . end
      )
      | .outbounds = ((.outbounds // []) + $nodes)
    ' ${runtimeDir}/config.base.json > ${runtimeDir}/config.merged.json
    rm -f ${runtimeDir}/nodes.json

    # ── 注入不变量（net-policy）────────────────────────────────────────
    # 分流规则主干整份来自 net-policy（单一事实源），地址取并集（unique 保证幂等）。
    #
    # 插入点：sniff / hijack-dns 这类带 action 的 mechanics 保持最前 —— 域名规则
    # 依赖 sniff 出来的域名，排在它前面等于让 domain 规则看不到域名。密文里若还留着
    # 手写分流（无 action），排在 policy 之后，不会抢掉断言里要求的那几条。
    #
    # auto_redirect_output_mark 也在这里覆盖，原因是本机 cilium 的 CILIUM_OUTPUT
    # 链会把非 magic 的 skb mark 归一化：mark and 0xfffff0ff xor 0xc00。sing-box
    # 默认的 0x2024 因此变成 0x2c24，它自己生成的 `not fwmark 0x2024 lookup 2022`
    # 规则随即命中，出站被塞回 TUN —— 日志表现为反复出现
    # "inbound connection to <节点地址>" 加 outbound/direct 的 i/o timeout。
    # 0x1c00 命中 cilium 的不改写分支（mark & 0xe00 == 0x800），改写对它是幂等的；
    # 0x1000 是 cilium 未使用的 k8s mark 位，既能和普通 host 流量的 0x0c00 区分，
    # 又不带 identity。
    jq -s --slurpfile addr ${netPolicyAddressPath} '
      # token 名就是 __NETPOLICY_<密文键>__，去首尾包装即得键，不用维护映射表。
      def np_lines($a):
        . as $t
        | ($t | ltrimstr("__NETPOLICY_") | rtrimstr("__")) as $k
        | ($a[$k] // error("net-policy-addresses 里没有键 \($k)"))[];
      def np_expand($a):
        map(if test("^__NETPOLICY_") then np_lines($a) else . end);

      .[1] as $p
      | ($addr[0]) as $a
      | .[0]
      | ([ (.route.rules // [])[] | select(.action == null) ] | length) as $handwritten
      | if $handwritten > 0 then
          error("密文里仍有 \($handwritten) 条手写分流规则：分流规则的单一事实源是 net-policy，密文里只允许 sniff / hijack-dns 这类有 action 的 mechanics")
        else . end
      | .route.rules = (
          ([ (.route.rules // [])[] | select(.action != null) ])
          # 旁路端口固定出站：必须排在分流规则之前，否则又被 IP-CIDR 直连抢走。
          # 同时必须排在 sniff / hijack-dns 之后 —— 那两条是 mechanics，先动不得。
          + ([ $p.forcedProxy | select(. != null) | { inbound: [ .tag ], outbound: .outbound } ])
          + $p.rules
          + ([ (.route.rules // [])[] | select(.action == null) ])
        )
      # 展开敏感地址 token。必须在这里（规则已合并进最终配置）而不是 nix
      # 侧：真实地址在密文里，nix 求值时读不到。用 |= 保持规则顺序不变。
      | .route.rules |= map(
          (if (.ip_cidr // []) | any(test("^__NETPOLICY_")) then .ip_cidr |= np_expand($a) else . end)
          | (if (.domain_suffix // []) | any(test("^__NETPOLICY_")) then .domain_suffix |= np_expand($a) else . end)
        )
      | .route.final = $p.final
      # ── DNS：代理入口域名必须真实解析 ───────────────────────────────
      # 这些域名一旦被 fakeip 改写，客户端（tuic-client 等）拿到 198.18.x 假地址，
      # 连过去又被 TUN 反查回域名走代理，自指了一圈。实测 2026-10-27。
      # 插在最前：只按 domain_suffix 匹配，不依赖 sniff；且必须排在密文里
      # query_type [A,AAAA] → fakeip 这条之前，否则被 fakeip 抢走。
      | .dns.rules = (
          [ { domain_suffix: ($p.dnsDirect | np_expand($a)), server: "dns-direct" } ]
          + (.dns.rules // [])
        )
      # ── fakeip v6 闸门 ────────────────────────────────────────────
      # 只在 net-policy 声明了段时才注入；null 时保持密文原样（fakeip 只有 v4）。
      # 打开后 AAAA 查询会返回该段的 fakeip 地址，应用才可能发起 v6 连接。
      | (if $p.fakeip6 != null
         then .dns.servers |= map(
                if .type == "fakeip" then .inet6_range = $p.fakeip6 else . end
              )
         else . end)
      # ── TUN：代理服务器地址永不进 TUN ───────────────────────────────
      # 光靠 route 规则里的 IP-CIDR → 直连 不够：包仍要先被 nfqueue 抓进 sing-box
      # 再 direct 出站，每条新 QUIC 连接都多绕一圈（表现为握手偶发超时）。
      #
      # 判断这条是否生效别看 nft set：`nft list set inet sing-box
      # inet4_route_exclude_address_set` 对应的是 `route_exclude_address_set`
      # （rule_set 引用），与 `route_exclude_address` 是两套机制。实测（2026-10-27）：
      # 加了 /32 和 /128 后 nft set 里仍看不到它们，但 sing-box 日志里不再出现
      # 这些目标的 inbound —— route_exclude_address 的作用点在 nfqueue 处理：
      # 包进了队列，但判断命中排除后直接放行，不记日志、不进代理。
      | .inbounds = (
          .inbounds
          # 旁路 socks 端口：只绑回环，避免开成对外代理。
          + ([ $p.forcedProxy
               | select(. != null)
               | { type: "socks", tag: .tag, listen: "127.0.0.1", listen_port: .port }
             ])
          | map(
              if .type == "tun"
              then .route_exclude_address = (
                     ((.route_exclude_address // [])
                       + $p.addresses
                       + ($p.tunnelExclude | np_expand($a)))
                     | unique
                   )
                   | .auto_redirect_output_mark = "0x1c00"
              else . end
            )
        )
    ' ${runtimeDir}/config.merged.json ${policyJson} > ${tmpConfigPath}
    rm -f ${runtimeDir}/config.base.json ${runtimeDir}/config.merged.json

    # ── 注入密码 ───────────────────────────────────────────────────────
    # 必须作用在**最终配置**上，不能只替换 base：hy2 节点的 password 字段也写
    # 同一个占位符，而节点是上一步才从 proxy-nodes 密文注入的。之前只替换 base
    # 且把残留检查放在节点合并之前，于是 sib 拿着字面量
    # __RELAY_HYSTERIA_PASSWORD__ 去认证，服务端一律回 419（masquerade 兜底），
    # 表现为两个 hy2 节点长期不可用、但 check 与自检全部通过。
    #
    # 密码由 token_urlsafe 生成，只含 [A-Za-z0-9_-]，sed 替换串无需转义。
    hy2_pw="$(tr -d '\n' < ${hy2PasswordPath})"
    sed -i "s|__RELAY_HYSTERIA_PASSWORD__|$hy2_pw|g" ${tmpConfigPath}
    remaining="$(grep -oE '__(RELAY|NETPOLICY)_[A-Za-z_]+__' ${tmpConfigPath} | sort -u | tr '\n' ' ' || true)"
    if [ -n "$remaining" ]; then
      echo "sib 最终配置里仍有未替换的占位符：$remaining" >&2
      exit 1
    fi

    # `sing-box check` 只校验语法与自身一致性，**不校验任何引用**（实测：把规则
    # 的 outbound / rule_set 改成不存在的值、或把 route.final 指向不存在的出站，
    # check 全部 exit 0）。这类错误要等 `sing-box run` 才 FATAL，而那时服务已经
    # 进重启循环、journal 里只有一行 FATAL。所以下面把四类引用一次核完：
    #   · selector/urltest 成员 → outbounds tag
    #   · rule.outbound        → outbounds tag
    #   · rule.rule_set[]      → route.rule_set[].tag
    #   · route.final          → outbounds tag
    badrefs="$(jq -r '
      ([.outbounds[].tag]) as $outs
      | ([.route.rule_set[]?.tag]) as $sets
      | ([.dns.servers[]?.tag]) as $dns_servers
      | [
          ( .outbounds[]
            | select(.outbounds != null)
            | . as $g
            | ($g.outbounds - $outs)[]
            | "组 \($g.tag) → 不存在的出站 \(.)" ),
          ( .route.rules[]
            | (.outbound // empty) as $o
            | select(($outs | index($o)) == null)
            | "规则 → 不存在的出站 \($o)" ),
          ( .route.rules[]
            | select(.rule_set != null)
            | .rule_set[] as $s
            | select(($sets | index($s)) == null)
            | "规则 → 不存在的 rule_set \($s)" ),
          ( .dns.rules[]
            | (.server // empty) as $s
            | select(($dns_servers | index($s)) == null)
            | "DNS 规则 → 不存在的 dns server \($s)" ),
          ( (.route.final // null) as $f
            | select($f != null)
            | select(($outs | index($f)) == null)
            | "route.final → 不存在的出站 \($f)" )
        ]
      | join("; ")
    ' ${tmpConfigPath})"
    if [ -n "$badrefs" ]; then
      echo "sib 配置里有指不存在的引用：$badrefs" >&2
      exit 1
    fi

    # 配置错误在启动前炸掉，并让 sing-box 自己把原因打到 journal。
    if ! ${cfg.package}/bin/sing-box check -c ${tmpConfigPath}; then
      echo "sib 配置自检失败，原因见上面 sing-box 的输出" >&2
      exit 1
    fi

    chmod 0600 ${tmpConfigPath}
    mv ${tmpConfigPath} ${configPath}
  '';
in
{
  options.${namespace}.sib = with lib; {
    enable = mkEnableOption "sing-box client (sib)";

    package = mkOption {
      type = types.package;
      default = sing-box;
      defaultText = lib.literalExpression "pkgs-unstable.sing-box（版本覆盖到 1.14.4）";
      description = "sing-box package to run.";
    };

    # 运行时配置路径。net-policy 的自检脚本要读它 —— 之前在两边各写一份
    # 文件名，重命名（config.json → config-with-secret.json）时静默漂开了：
    # 自检报「配置不存在」，而真正的原因只是文件名叫法不同。
    configPath = mkOption {
      type = types.str;
      internal = true;
      readOnly = true;
      default = configPath;
      description = "单实例运行用的最终配置路径（已注入密码）。";
    };

    configSecretFile = mkOption {
      type = types.str;
      default = "sib-conf/zen14.json.age";
      description = ''
        inputs.mysecrets 下的加密 sing-box 配置。
        里面的中转密码写 `__RELAY_HYSTERIA_PASSWORD__`，启动时从
        relay/hysteria-password 注入。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.${namespace}.miho.enable;
        message = ''
          ${namespace}.sib 与 ${namespace}.miho 不能同时启用：两者都要接管 TUN、
          127.0.0.1:53 和 nftables。切换时在主机配置里一开一关。
        '';
      }
    ];

    environment.systemPackages = [ cfg.package ];

    age.secrets."sib-conf" = {
      file = "${mysecrets}/${cfg.configSecretFile}";
    };

    # 节点清单由 sib / miho 共用；两个模块同时声明同一份文件时只是合并，不冲突。
    age.secrets."proxy-nodes".file = "${mysecrets}/proxy-nodes.json.age";

    # miho 关掉后这个 secret 没有别的声明方，sib 自己声明；
    # 两个模块同时声明同一份文件时只是合并，不冲突。
    age.secrets."relay/hysteria-password".file = "${mysecrets}/relay/hysteria-password.age";

    systemd.services.sib-prepare-config = {
      description = "Prepare sib (sing-box) config";
      before = [ "sib.service" ];
      after = [ "run-agenix.d.mount" ];
      # 注意：agenix 在本仓库是 activation script 安装的（/run/agenix 指向
      # /run/agenix.d/<generation>），没有 agenix.service 单元。
      requires = [ "run-agenix.d.mount" ];
      # 重启 sib 时连带重跑本单元，换完密码只需 systemctl restart sib
      partOf = [ "sib.service" ];
      path = with pkgs; [
        coreutils
        gnused
        gnugrep
        jq
      ];
      serviceConfig = {
        Type = "oneshot";
        # 用 ExecStart 指向脚本：systemd 的 script= 只接受字符串，不接受 derivation
        ExecStart = prepareConfigScript;
      };
    };

    systemd.services.sib = {
      description = "sing-box (sib) client";
      after = [
        "network-online.target"
        "sib-prepare-config.service"
        # 软依赖：1086/1087 那两个 socks 节点来自 xray-client，先起它只是减少
        # 「启动瞬间节点不可用」的窗口。用 wants 而不是 requires —— xray 挂了
        # 不该连累整个代理起不来，那两条节点交给 url-test 跳过即可。
        "xray-client.service"
      ];
      wants = [
        "network-online.target"
        "xray-client.service"
      ];
      requires = [ "sib-prepare-config.service" ];
      wantedBy = [ "multi-user.target" ];
      # 与 mihomo 互斥：即便有人手动 start，也不会两个 TUN 同时存在
      conflicts = [ "mihomo.service" ];
      # 密文内容变了就重启（agenix 路径稳定，unit 文本不变，不写这条不会动）。
      # 用内容哈希而不是 store 路径：换无关 secrets 不连带重启。
      restartTriggers = [
        (builtins.hashFile "sha256" "${mysecrets}/${cfg.configSecretFile}")
        (builtins.hashFile "sha256" "${mysecrets}/relay/hysteria-password.age")
        (builtins.hashFile "sha256" "${mysecrets}/proxy-nodes.json.age")
        (builtins.hashFile "sha256" "${mysecrets}/net-policy-addresses.json.age")
        # net-policy 的不变量变了也要重启 —— 否则 prepare-config 重算出的配置
        # 没人用，表现为「改了 nix 但行为没变」。
        policyJson
      ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/sing-box run -c ${configPath}";
        Restart = "on-failure";
        RestartSec = "3s";
        # cache.db 落在这里（配置里 experimental.cache_file.path 指向同一处）
        StateDirectory = "sib";
        StateDirectoryMode = "0700";
        # 需要的能力（少一个就会以难懂的方式坏掉）：
        #   CAP_NET_ADMIN      TUN 建卡、auto_redirect 的 nftables、ip rule
        #   CAP_NET_BIND_SERVICE 绑定 127.0.0.1:53
        #   CAP_NET_RAW        SO_BINDTODEVICE（auto_detect_interface 给每个出站
        #                      socket 绑网卡）。缺它时所有 UDP 出站报
        #                      "listen udp4 :0: operation not permitted"，
        #                      表现为 hy2/QUIC 全 504 而 TCP 节点正常。
        AmbientCapabilities = [
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_RAW"
        ];
        CapabilityBoundingSet = [
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_RAW"
        ];
      };
    };
  };
}
