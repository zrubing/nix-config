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

  # 渲染管线的唯一实现。原先这段逻辑内嵌在下面的 systemd unit 里，任何需要
  # “生成一份等价配置”的场合都得复制一遍；抽成脚本后 prepare 与导出共用它。
  mihomoRender = pkgs.callPackage ../../../packages/mihomo-render { };

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

    # 渲染产物路径，无条件求值（不随 enable 开关变化）：导出工具需要它们，
    # 但启用与否不该决定“能不能拿到输入”。internal 是因为它们只是内部管道。
    rendered = {
      extraConfigFile = mkOption {
        type = types.path;
        readOnly = true;
        internal = true;
        description = "合并后的 extraConfig（含 net-policy 规则），YAML 文件";
      };
      tokensFile = mkOption {
        type = types.path;
        readOnly = true;
        internal = true;
        description = "net-policy 的 token 声明（dnsDirect/tunnelExclude/fakeip6/forcedProxy）";
      };
    };
  };

  config = lib.mkMerge [
    {
      ${namespace}.miho.rendered = {
        extraConfigFile = mihomoExtraConfigFile;
        tokensFile = netPolicyTokensJson;
      };
    }

    (lib.mkIf cfg.enable {

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

        # 渲染：base（age 密文）+ extraConfig（nix 侧声明）+ 节点清单 + token 展开。
        # 全部交给 mihomo-render —— 这是这段逻辑的唯一实现，导出工具用的是同一份。
        # 合并语义与几个必须保持一致的细节（对象深合并、数组追加、rules 整份来自
        # extra、base 里出现 rules 直接报错、__NETPOLICY_<键>__ 展开成多条）都写在
        # 那个脚本里，这里只负责把四份运行时输入喂进去。
        # 不把节点清单放进 nix 求值——那会把 server/密码落进世界可读的 /nix/store。
        ${mihomoRender}/bin/mihomo-render \
          --base /run/agenix/miho-conf \
          --extra ${mihomoExtraConfigFile} \
          --nodes-raw ${proxyNodesSecretPath} \
          --nodes-jq ${proxyNodesJq} \
          --tokens ${netPolicyTokensJson} \
          --addresses ${netPolicy.addressTokenFile} \
          --out /run/mihomo/config.merged.yaml

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
    })
  ];

}
