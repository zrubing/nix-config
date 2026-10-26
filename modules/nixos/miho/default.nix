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

    # resolved 的上游就是本机的 mihomo DNS（listen 127.0.0.1:53，见
    # build-node-extra-config.nix 里那条 listen 覆盖）。这个值属于「当前用哪个
    # 代理」，所以由代理模块声明，不放在 modules/nixos/networking。
    services.resolved.settings.Resolve.DNS = [ "127.0.0.1" ];

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

        # 两个输入都要就绪：主配置 + hysteria2 密码 + 节点清单
        for f in miho-conf relay/hysteria-password proxy-nodes; do
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
        yq eval --null-input '
          load("/run/agenix/miho-conf") as $base |
          load("${mihomoExtraConfigFile}") as $extra |
          load("/run/mihomo/nodes.json") as $nodes |
          (($base *+ ($extra | del(.rules)))
            | .proxies = ((.proxies // []) + ($nodes.miho // []))
            | .rules = $extra.rules)
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
      after = [ "mihomo-prepare-config.service" ];
      requires = [ "mihomo-prepare-config.service" ];
      # 密文 / extraConfig 内容变了要重启。agenix 路径是稳定的 /run/agenix/...，
      # unit 文本不变时 nixos-rebuild 不会动服务；用内容哈希做触发器，避免
      # 换无关 secrets 时被连带重启。
      restartTriggers = [
        (builtins.hashFile "sha256" "${mysecrets}/miho-conf/zen14-test.age")
        (builtins.hashFile "sha256" "${mysecrets}/relay/hysteria-password.age")
        (builtins.hashFile "sha256" "${mysecrets}/proxy-nodes.json.age")
        mihomoExtraConfigFile
      ];
      serviceConfig = {
        AmbientCapabilities = lib.mkForce "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = lib.mkForce "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
      };
    };

  };

}
