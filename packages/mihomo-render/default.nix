{
  writeShellApplication,
  jq,
  yq-go,
  coreutils,
}:

# mihomo 配置渲染器：把「加密的 base 配置」与「nix 侧的偏好声明」合成一份
# 可直接启动的 YAML（密码仍是占位符，由调用方替换）。
#
# 抽成独立脚本的原因：同一套合并语义原先内嵌在 mihomo-prepare-config 的
# systemd unit 里，任何需要“生成一份等价配置”的场合（导出给别的客户端、
# 生成测试样本）都得复制一遍，而这段逻辑有几个必须保持一致的细节：
#
#   · 对象逐键深合并，extra 胜出；数组用 `*+` **追加**（proxies 天然是多份）；
#   · `rules` 整份来自 extra，不参与合并，且 base 里出现 `rules` 直接报错——
#     两边对“密文里的 rules”处理本来就不一致（sib 会生效，miho 会被顶到
#     MATCH 之后失效），同一种写法两种结果，所以不留这个入口；
#   · 规则里的 `__NETPOLICY_<键>__` token 必须展开成多条，真值在
#     net-policy-addresses.json；token 不是合法 CIDR/域名，忘展开时 mihomo
#     加载会直接报错，不会静默跑错。
writeShellApplication {
  name = "mihomo-render";

  runtimeInputs = [
    jq
    yq-go
    coreutils
  ];

  text = ''
    usage() {
      cat <<'EOF'
    mihomo-render - 合成 mihomo 配置（密码保留占位符）

    用法:
      mihomo-render --base <yaml> --extra <yaml> --nodes-raw <json> \
                    --nodes-jq <jq> --tokens <json> --addresses <json> \
                    --out <yaml>

    必需参数:
      --base       加密的 base 配置（mihomo 方言 YAML）
      --extra      nix 侧的偏好声明（含 rules 与 tun）
      --nodes-raw  节点清单明文 JSON（唯一事实源）
      --nodes-jq   节点清单到 mihomo 方言的转换器（lib/proxy-nodes.jq）
      --tokens     net-policy 的 token 声明 JSON
      --addresses  net-policy 的敏感地址表 JSON（token 展开来源）
      --out        输出文件路径（- 表示 stdout）

    环境变量:
      无
    EOF
    }

    base="" extra="" nodes_raw="" nodes_jq="" tokens="" addresses="" out=""

    while [ $# -gt 0 ]; do
      case "$1" in
        --base)      base="$2"; shift 2 ;;
        --extra)     extra="$2"; shift 2 ;;
        --nodes-raw) nodes_raw="$2"; shift 2 ;;
        --nodes-jq)  nodes_jq="$2"; shift 2 ;;
        --tokens)    tokens="$2"; shift 2 ;;
        --addresses) addresses="$2"; shift 2 ;;
        --out)       out="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
      esac
    done

    for v in base extra nodes_raw nodes_jq tokens addresses out; do
      if [ -z "''${!v}" ]; then
        echo "缺少必需参数: --''${v//_/-}" >&2
        exit 2
      fi
    done

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT

    # 拒绝 base 里自带 rules：分流规则只由 net-policy 声明。
    if [ "$(yq eval 'has("rules")' "$base")" = "true" ]; then
      echo "base 配置里有 rules：分流规则只由 net-policy 声明，请从密文删掉" >&2
      exit 1
    fi

    # 节点清单：按 mihomo 方言转换后并入 proxies。
    jq -f "$nodes_jq" "$nodes_raw" > "$workdir/nodes.json"

    # 规则 token 展开。用 jq 而不是 yq：yq-go 不支持 if/then 表达式，而这里
    # 需要「一条字符串变多条」（IP-CIDR / DOMAIN-SUFFIX 一条一个值）。
    yq -o=json -I=0 '.rules' "$extra" > "$workdir/rules.tmpl.json"
    jq --slurpfile a "$addresses" '
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
    ' "$workdir/rules.tmpl.json" > "$workdir/rules.json"

    # 代理入口 token 展开成几个纯数组；条件性注入（fakeip v6 段、旁路端口）
    # 在 jq 侧算成可直接深合并的对象 —— yq 里写 if 会 lexer 报错。
    jq --slurpfile a "$addresses" '
      def np_lines($addr):
        . as $t
        | ($t | ltrimstr("__NETPOLICY_") | rtrimstr("__")) as $k
        | ($addr[$k] // error("net-policy-addresses 里没有键 \($k)"))[];
      def np_expand($addr):
        map(if test("^__NETPOLICY_") then np_lines($addr) else . end);
      { fake_ip_filter: (.dnsDirect | np_expand($a[0])),
        route_exclude: (.tunnelExclude | np_expand($a[0])),
        dns_extra: (if .fakeip6 != null then { "fake-ip-range6": .fakeip6 } else {} end),
        listener_extra:
          (if .forcedProxy != null
           then [ { name: .forcedProxy.name, type: "socks",
                    port: .forcedProxy.port, listen: "127.0.0.1",
                    proxy: .forcedProxy.proxy } ]
           else [] end) }
    ' "$tokens" > "$workdir/net-policy.json"

    yq eval --null-input "
      load(\"$base\") as \$base |
      load(\"$extra\") as \$extra |
      load(\"$workdir/nodes.json\") as \$nodes |
      load(\"$workdir/rules.json\") as \$rules |
      load(\"$workdir/net-policy.json\") as \$np |
      ((\$base *+ (\$extra | del(.rules)))
        | .proxies = ((.proxies // []) + (\$nodes.miho // []))
        | .rules = \$rules
        | .dns[\"fake-ip-filter\"] = (((.dns[\"fake-ip-filter\"] // []) + \$np.fake_ip_filter) | unique)
        | .tun[\"route-exclude-address\"] = (((.tun[\"route-exclude-address\"] // []) + \$np.route_exclude) | unique)
        | .dns = ((.dns // {}) * \$np.dns_extra)
        | .listeners = ((.listeners // []) + \$np.listener_extra))
    " > "$workdir/out.yaml"

    if [ "$out" = "-" ]; then
      cat "$workdir/out.yaml"
    else
      # 生成物含凭据占位符与节点信息，默认只给属主读。
      install -m 0600 "$workdir/out.yaml" "$out"
    fi
  '';

  meta = {
    description = "合成 mihomo 配置（密码保留占位符）";
    mainProgram = "mihomo-render";
  };
}
