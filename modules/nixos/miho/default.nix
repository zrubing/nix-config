{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  mysecrets = inputs.mysecrets;
  cfg = config.${namespace}.miho;

  # ── 不变量渲染器（单一事实源：modules/nixos/net-policy）────────────────
  #
  # policy 的条目**优先且取并集**：extraConfig 是「本机代理偏好」，可以调节点、
  # 加规则；但「NTP 直连」「ET/集群网段不进代理」这类不变量不能因为
  # extraConfig 里写了同名字段就被顶掉 —— 所以这里先放 policy，再拼 extra。
  #
  # 顺序上 policy 的规则在最前（rule 表首条匹配），保证它不会被
  # `RULE-SET,geolocation-!cn` 这类宽规则提前命中。
  netPolicy = config.${namespace}.netPolicy;
  policyAddresses = netPolicy.bypassProxyAddresses;

  # 共享节点清单（私有仓的加密 JSON）是唯一事实源。节点定义刻意不经 nix 求值：
  # 一旦渲染成 store 文件，server/跳端口/密码/SNI 就是世界可读的 /nix/store 明文。
  # 进 store 的只有方言转换器 lib/proxy-nodes.jq，prepare 服务在运行时
  # 解密 → 转换 → 合并。
  proxyNodesSecretPath = config.age.secrets."proxy-nodes".path;
  proxyNodesJq = ../../../lib/proxy-nodes.jq;

  mergedExtraConfig = cfg.extraConfig // {
    # 规则主干整份来自 net-policy（单一事实源，含 bypassProxyPorts 的直连规则）。
    # 顺序：不变量 → extraConfig 偏好 → 兜底 MATCH。MATCH 必须最后一条，
    # 因为 mihomo 首条匹配 —— 追加在它后面的规则永远不会生效（曾经就是这么写的）。
    rules = netPolicy.mihoRules
      ++ (cfg.extraConfig.rules or [ ])
      ++ [ "MATCH,${netPolicy.final}" ];
    tun = (cfg.extraConfig.tun or { }) // {
      route-exclude-address = lib.unique (
        policyAddresses ++ (cfg.extraConfig.tun.route-exclude-address or [ ])
      );
    };
  };

  mihomoExtraConfigFile = (pkgs.formats.yaml { }).generate "mihomo-extra.yaml" mergedExtraConfig;

  # 代理入口的两条不变量（同为 token，prepare 阶段从密文展开，与 sib 同源）：
  #   dnsDirect     → dns.fake-ip-filter（mihomo 默认 blacklist：列进去的域名不走 fake-ip）
  #   tunnelExclude → tun.route-exclude-address（连服务器本身不进 TUN）
  #
  # 已验证（2026-10-26 ~ 27，nova13 实际跑 mihomo 期间核对过）：
  #   · /run/mihomo/config-with-secret.yaml 的 dns.fake-ip-filter 含全部节点域名
  #   · tun.route-exclude-address 含 directCidrs 的全部条目
  #   · 密文里没有 dns.fake-ip-filter-mode: whitelist
  #
  # 但三条仍需在回切时复核：它们取决于密文与 net-policy 的内容，而不是本段代码。
  # 密文里一旦有人加上 fake-ip-filter-mode: whitelist，语义就反过来，本段会错。
  netPolicyTokensJson = (pkgs.formats.json { }).generate "miho-net-policy-tokens.json" {
    dnsDirect = netPolicy.dnsDirectDomainTokens;
    tunnelExclude = netPolicy.tunnelExcludeTokens;
    # null = 关闭 fakeip v6（不写 fake-ip-range6）
    fakeip6 = netPolicy.fakeipInet6Range;
    # 旁路 socks 端口：固定出站、不看 rules。null = 不开监听。
    forcedProxy =
      if netPolicy.forcedProxySocksPort == null then
        null
      else
        {
          port = netPolicy.forcedProxySocksPort;
          name = "forced-proxy-in";
          proxy = netPolicy.forcedProxyOutbound;
        };
  };
in
{

  options.${namespace}.miho = with lib; {
    enable = mkEnableOption "Enable mihomo";
    extraConfig = mkOption {
      type = types.attrs;
      default = { };
    };
  };

  config = lib.mkIf cfg.enable {

    environment.systemPackages = [ pkgs.${namespace}.mihomo ];

    age.secrets.miho-conf.file = "${mysecrets}/miho-conf/zen14-test.age";

    # 节点清单由 sib / miho 共用；两个模块同时声明同一份文件时只是合并，不冲突。
    age.secrets."proxy-nodes".file = "${mysecrets}/proxy-nodes.json.age";

    # 中转凭据与配置分离：加密的 miho-conf 里只留占位符，真实值在激活时注入。
    # 轮换密码只需要换 nix-secrets 里的 relay/*.age，不用重写整份 YAML。
    # tuic 的凭据不在这里：mihomo 已经没有 tuic 节点，它连的是本机 tuic-client
    # 开的 socks5（见 modules/nixos/tuic-client），uuid/password 由那边读。
    age.secrets."relay/hysteria-password".file = "${mysecrets}/relay/hysteria-password.age";

    services.mihomo = {
      enable = true;
      package = pkgs.${namespace}.mihomo;
      configFile = "/run/mihomo/config-with-secret.yaml";
      tunMode = true;
    };

    systemd.services.mihomo-prepare-config = {
      description = "Prepare merged mihomo config";
      before = [ "mihomo.service" ];
      after = [ "run-agenix.d.mount" ];
      # 注意：agenix 在本仓库是 activation script 安装的（/run/agenix 指向
      # /run/agenix.d/<generation>），并没有 agenix.service 这个单元。
      # 写成 Requires=agenix.service 会让 mihomo 直接起不来：
      #   Failed to restart mihomo.service: Unit agenix.service not found.
      requires = [ "run-agenix.d.mount" ];
      # 重启 mihomo 时连带重跑本单元，这样换完密钥只需 systemctl restart mihomo
      partOf = [ "mihomo.service" ];
      path = with pkgs; [
        coreutils
        iproute2
        jq
        yq-go
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -euo pipefail

        # 两个输入都要就绪：主配置 + hysteria2 密码 + 节点清单 + 敏感地址表
        for f in miho-conf relay/hysteria-password proxy-nodes net-policy-addresses; do
          i=0
          while [ "$i" -lt 60 ]; do
            [ -s "/run/agenix/$f" ] && break
            i=$((i + 1))
            sleep 1
          done
          if [ ! -s "/run/agenix/$f" ]; then
            echo "/run/agenix/$f is missing or empty after 60s" >&2
            ls -la /run/agenix /run/agenix.d 2>/dev/null || true
            exit 1
          fi
        done

        ip -4 addr show dev lo | grep -q '169.254.53.53/32' || ip addr add 169.254.53.53/32 dev lo

        install -d -m 0700 /run/mihomo

        # 节点清单：加密 JSON 是唯一事实源，这里按 mihomo 方言转换后合并进 proxies。
        # 不在 nix 求值里渲染——那会把 server/密码落进世界可读的 /nix/store。
        jq -f ${proxyNodesJq} ${proxyNodesSecretPath} > /run/mihomo/nodes.json

        # ── 合并 base（age 密文）+ extraConfig（nix 侧声明）─────────────
        #
        # 分流规则的单一事实源是 net-policy（已在 extra 里渲染好，末尾带 MATCH）。
        # 密文里不许再写 rules —— 两边对「密文里的 rules」处理本来就不一致
        # （sib 保留生效，miho 这边会被顶到 MATCH 之后而失效），同一种写法
        # 两种结果，所以直接拒绝，不留这个入口。
        if [ "$(yq eval 'has("rules")' /run/agenix/miho-conf)" = "true" ]; then
          echo "miho-conf 里有 rules：分流规则只由 net-policy 声明，请从密文删掉" >&2
          exit 1
        fi
        #
        # 语义（一次合并说清，别再拆成两次）：
        #   · 对象：逐键深度合并，extraConfig 胜出 —— `dns.listen` 这类覆盖靠它；
        #   · 数组：**追加**（`*+`）。`proxies` / `proxy-groups` 这类天然是“多一份”；
        #   · `rules`：整份来自 extra，不参与合并（见上面的断言）。
        #
        # ⚠️ 曾经的写法是「先 `*+` 再 `*`」两次合并，而 `*` 对数组是**整体替换**：
        #    只要 extraConfig 里写了 `rules`，base 的 29 条分流规则会被削成那 1 条
        #    （2026-10-26 实测：最终 rules 只剩 `DST-PORT,123,DIRECT`），全机分流
        #    静默失效。
        #
        # 用 load() 一次读完三份文件，不再有“第二次合并把第一次结果覆盖掉”这种
        # 必须读代码才能发现的隐式行为。
        # 敏感地址 token 展开。net-policy 的 rules 里只有 __NETPOLICY_<键>__，
        # 真值在 net-policy-addresses.json.age；token 不是合法 CIDR / 域名，
        # 忘展开时 mihomo 加载配置会直接报错，不会静默跑错。
        #
        # 用 jq 而不是 yq：yq-go 4.53 不支持 if/then 表达式，而这里需要
        # 「一条字符串变多条」（Mihomo 的 IP-CIDR / DOMAIN-SUFFIX 一条一个值）。
        # 先导成 JSON 再导回，保持规则顺序不变。
        yq -o=json -I=0 '.rules' "${mihomoExtraConfigFile}" > /run/mihomo/rules.tmpl.json
        jq --slurpfile a ${netPolicy.addressTokenFile} '
          def np_lines($addr):
            . as $t
            | ($t | ltrimstr("__NETPOLICY_") | rtrimstr("__")) as $k
            | ($addr[$k] // error("net-policy-addresses 里没有键 \($k)"))[];
          def expand_rule($addr):
            if test("__NETPOLICY_") then
              capture("^(?<t>[^,]+),(?<v>[^,]+),(?<rest>.*)$") as $m
              | [ $m.v | np_lines($addr) ] as $vals
              | $vals[] as $v | "\($m.t),\($v),\($m.rest)"
            else . end;
          map(expand_rule($a[0]))
        ' /run/mihomo/rules.tmpl.json > /run/mihomo/rules.json
        rm -f /run/mihomo/rules.tmpl.json

        # 代理入口 token 展开（与 sib 同一套 token 名，同一份 net-policy-addresses）。
        # 展开成两个纯数组，下面交给 yq 合并 —— yq 里不方便写「一条 token 变多条」。
        jq --slurpfile a ${netPolicy.addressTokenFile} '
          def np_lines($addr):
            . as $t
            | ($t | ltrimstr("__NETPOLICY_") | rtrimstr("__")) as $k
            | ($addr[$k] // error("net-policy-addresses 里没有键 \($k)"))[];
          def np_expand($addr):
            map(if test("^__NETPOLICY_") then np_lines($addr) else . end);
          { fake_ip_filter: (.dnsDirect | np_expand($a[0])),
            route_exclude: (.tunnelExclude | np_expand($a[0])),
            # fakeip v6 闸门：段在 jq 侧就算成一个可直接深合并的小对象。
            # 不能在 yq 里写 if —— yq 的表达式只实现了 jq 的子集，遇到 `if`
            # 直接 lexer 报错（2026-10-27 nova13 首次真正跑 miho 时炸出）。
            dns_extra: (if .fakeip6 != null then { "fake-ip-range6": .fakeip6 } else {} end),
            # 旁路 listener 同理：在这里拼成可直接追加的数组，yq 只做 +
            listener_extra:
              (if .forcedProxy != null
               then [ { name: .forcedProxy.name, type: "socks",
                        port: .forcedProxy.port, listen: "127.0.0.1",
                        proxy: .forcedProxy.proxy } ]
               else [] end) }
        ' ${netPolicyTokensJson} > /run/mihomo/net-policy.json

        yq eval --null-input '
          load("/run/agenix/miho-conf") as $base |
          load("${mihomoExtraConfigFile}") as $extra |
          load("/run/mihomo/nodes.json") as $nodes |
          load("/run/mihomo/rules.json") as $rules |
          load("/run/mihomo/net-policy.json") as $np |
          (($base *+ ($extra | del(.rules)))
            | .proxies = ((.proxies // []) + ($nodes.miho // []))
            | .rules = $rules
            # 代理入口域名走真实 DNS：命中 fake-ip-filter 的域名用 direct-nameserver
            # 解析，不会被改写成 198.18.x。否则客户端连服务器拿到假地址，
            # 连接被 TUN 反查回域名后走代理，QUIC 握手被塞进另一个代理的 UDP 通道。
            | .dns["fake-ip-filter"] = (((.dns["fake-ip-filter"] // []) + $np.fake_ip_filter) | unique)
            | .tun["route-exclude-address"] = (((.tun["route-exclude-address"] // []) + $np.route_exclude) | unique)
            # fakeip v6 闸门：段在 jq 侧已算成 dns_extra（声明了段才有内容），
            # 这里只做一次深合并；yq 不支持 if，见上面 jq 段的注释。
            | .dns = ((.dns // {}) * $np.dns_extra)
            # 旁路 socks 端口：追加到 listeners，mihomo 的 proxy 字段表示
            # 「不经过 rules，直接走这个出站」。
            | .listeners = ((.listeners // []) + $np.listener_extra))
        ' > /run/mihomo/config.merged.yaml

        # 占位符替换。密码由 token_urlsafe 生成，只含 [A-Za-z0-9_-]，
        # sed 的替换串里不会出现需要转义的字符。
        #
        # 命名约定：中间产物（合并后、仍是占位符）叫 config.merged.yaml，
        # 只有替换过密码的最终文件才叫 config-with-secret.yaml —— 让任何人
        # （包括 agent）一眼看出哪份文件含明文凭据，不会误 cat。
        hy2_pw="$(tr -d '\n' < ${config.age.secrets."relay/hysteria-password".path})"
        sed \
          -e "s|__RELAY_HYSTERIA_PASSWORD__|$hy2_pw|g" \
          /run/mihomo/config.merged.yaml > /run/mihomo/config-with-secret.yaml.tmp

        if grep -q "__RELAY_" /run/mihomo/config-with-secret.yaml.tmp; then
          echo "mihomo 配置里仍有未替换的占位符" >&2
          exit 1
        fi

        chmod 0600 /run/mihomo/config-with-secret.yaml.tmp
        mv /run/mihomo/config-with-secret.yaml.tmp /run/mihomo/config-with-secret.yaml
        rm -f /run/mihomo/config.merged.yaml
      '';
    };

    systemd.services.mihomo = {
      # xray-client 提供 1086/1087 两个本地 socks5（xhttp 与 reality 节点靠它）。
      # 用 wants 而不是 requires：xray 挂了不该连累整个代理起不来，那两条节点
      # 交给 url-test 跳过即可；但启动顺序上先等它，缩短「代理已起、节点还没
      # 监听」的窗口。只在启用了 xray-client 的机器上加，避免无意义依赖。
      after =
        [ "mihomo-prepare-config.service" ]
        ++ lib.optional config.${namespace}.xray-client.enable "xray-client.service";
      wants = lib.optional config.${namespace}.xray-client.enable "xray-client.service";
      requires = [ "mihomo-prepare-config.service" ];
      # 密文 / extraConfig 内容变了要重启。agenix 路径是稳定的 /run/agenix/...，
      # unit 文本不变时 nixos-rebuild 不会动服务；用内容哈希做触发器，避免
      # 换无关 secrets 时被连带重启。
      restartTriggers = [
        (builtins.hashFile "sha256" "${mysecrets}/miho-conf/zen14-test.age")
        (builtins.hashFile "sha256" "${mysecrets}/relay/hysteria-password.age")
        (builtins.hashFile "sha256" "${mysecrets}/proxy-nodes.json.age")
        (builtins.hashFile "sha256" "${mysecrets}/net-policy-addresses.json.age")
        mihomoExtraConfigFile
        netPolicyTokensJson
      ];
      serviceConfig = {
        AmbientCapabilities = lib.mkForce "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = lib.mkForce "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
      };
    };

  };

}
