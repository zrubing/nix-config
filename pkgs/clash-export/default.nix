{
  writeShellApplication,
  mihomoRender,
  agenix,
  coreutils,
  gnused,
  jq,
  yq-go,
  lib,
  # 由调用方从 nixosConfigurations.<host>.config 注入 —— 包本身拿不到模块求值结果
  extraConfigFile,
  tokensFile,
  nodesJq,
  nodesMergeJq,
  agenixRules,
  # 密文所在目录（flake input 的 store 路径）+ 仓库内相对路径
  secretsRoot,
  mihoConfRel,
  # 节点清单拆两份：meta 明文（不加密，直接读），creds 密文（agenix 解）
  nodesMetaRel,
  nodesCredsRel,
  relayPasswordRel,
  addressesRel,
  # 手机端私有覆盖（加密）。含内网主机名等不该进公开仓库的定向规则。
  mobileExtraRel ? "",
}:

# 导出一份 Clash 方言的完整配置（含节点凭据），用于交给别的客户端。
#
# 与 mihomo 运行时用的是同一条渲染管线（mihomo-render）：解析语义只有一份实现，
# 导出物与机器上跑的东西不会漂移。区别只在最终落点 —— 这里写到指定文件，
# 且不碰 /run、不重启任何服务。
#
# 凭据处理：四份密文在本地用 agenix 现解，只在临时目录里存在；输出物含明文
# 密码，因此权限固定 0600。加密投递交给 handoff，不要直接放到可公开访问的位置。
writeShellApplication {
  name = "clash-export";

  runtimeInputs = [
    mihomoRender
    agenix
    coreutils
    gnused
    jq
    yq-go
  ];

  text = ''
    usage() {
      cat <<'EOF'
    clash-export - 导出一份完整的 Clash 配置

    用法:
      clash-export [-o <输出文件>] [--stdout]

    选项:
      -o, --out <路径>   写到指定文件（默认 ./exported.yaml，权限 0600）
      --stdout           写到标准输出（含明文凭据，慎用于管道/重定向）
      --raw              不做移动端适配，原样输出机器上跑的那份
      --mobile-extra <路径>
                         移动端额外合并这份 YAML：rules 前置，其余键覆盖。
                         可重复给多次，按出现顺序依次合并。用于声明手机专属
                         项，避免手改产物后下次导出又漂回去。与 --raw 互斥。
                         仓库里的手机端覆盖只有加密那一份（miho-conf/
                         mobile-extra.yaml.age，自动合并）；仓库内不放明文
                         覆盖文件。
      -h, --help         显示本帮助

    说明:
      · 节点与地址密文在本地现解，只在临时目录存在；
      · 与机器上运行中的配置同源（同一条渲染管线），不是另写一份；
      · 默认剔掉只对 Linux 主机成立的部分（见下） —— 手机端启动会不兼容；
      · 移动端模式会剔掉本机 socks5 上游（127.0.0.1:1086/1087/12190-12193）；
        原生 xhttp/reality 节点来自节点清单，不受影响；--raw 不剔除；
      · 产物含明文密码，默认 0600。

    默认剔除的字段（--raw 保留）:
      dns.listen          手机非 root 绑不了 53，交给客户端自己管
      listeners           0.0.0.0 监听在手机上是多余暴露面
      tun.auto-redirect   Linux nftables 特性，Android 用 VpnService 不认
      tun.auto-redirect-output-mark   同上，skb mark 只对 Linux 本机有意义
      tun.dns-hijack      同上，由客户端接管

    默认关掉的 IPv6（--raw 保留）:
      ipv6                节点域名同时有 A/AAAA，手机有原生 v6 时 mihomo 会
                          优先走 AAAA；该 v6 到节点服务器常是黑洞（2026-10-31
                          实测 ping6 节点 100% 丢包、TCP 连接 6s 超时），每条
                          连接都要等一次 v6 超时才回落 v4，表现就是“连不上/
                          很慢”。桌面没有 v6 出口所以从没触发过。
      dns.ipv6            同上：不再返回 AAAA，应用不会先试 v6
      dns.fake-ip-range6  没有 v6 出口就不要再分配 fake v6 地址
      （TUN 侧同样没有 v6 地址：FlClash 的 VpnService 只配了 198.18.0.1/30）
    EOF
    }

    out="exported.yaml"
    to_stdout=0
    raw=0
    mobile_extras=()

    while [ $# -gt 0 ]; do
      case "$1" in
        -o|--out)  out="$2"; shift 2 ;;
        --stdout)  to_stdout=1; shift ;;
        --raw)     raw=1; shift ;;
        --mobile-extra) mobile_extras+=("$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
      esac
    done

    if [ "$raw" -eq 1 ] && [ ''${#mobile_extras[@]} -gt 0 ]; then
      echo "--mobile-extra 只在移动端适配下生效，与 --raw 互斥" >&2
      exit 2
    fi
    for f in ''${mobile_extras[@]+"''${mobile_extras[@]}"}; do
      [ -f "$f" ] || { echo "mobile-extra 不存在: $f" >&2; exit 2; }
    done

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT

    # agenix 的 rules 用**仓库内相对路径**作属性名，所以必须先进到密文根目录
    # 用相对路径调用；直接传 /nix/store/... 绝对路径会匹配不上并报
    # "needs a rules file"。
    export AGENIX_RULES="''${AGENIX_RULES:-${agenixRules}}"
    secrets_root=${secretsRoot}

    decrypt() {
      local rel="$1" dest="$2"
      ( cd "$secrets_root" && agenix -d "$rel" ) > "$dest" 2>/dev/null || {
        echo "解密失败: $rel" >&2
        echo "提示：需要 age 私钥（~/.ssh/id_ed25519）与 AGENIX_RULES" >&2
        exit 1
      }
      [ -s "$dest" ] || { echo "解密结果为空: $rel" >&2; exit 1; }
    }

    # 五份输入：base 配置、节点 meta（明文）、节点 creds（密文）、中转密码、地址表
    decrypt ${mihoConfRel}      "$workdir/base.yaml"
    decrypt ${nodesCredsRel}    "$workdir/nodes-creds.json"
    decrypt ${relayPasswordRel} "$workdir/hy2-password"
    decrypt ${addressesRel}     "$workdir/addresses.json"

    # meta（在不在）+ creds（连哪里）→ 转换器的输入，与主机上的 prepare 同一份逻辑。
    jq -f ${nodesMergeJq} --slurpfile c "$workdir/nodes-creds.json" \
      "$secrets_root/${nodesMetaRel}" > "$workdir/nodes.json"

    # 渲染（与 mihomo-prepare-config 同一条管线），密码仍是占位符。
    # 移动端固定按“没有 v6 出口”渲染：与本机 miho 在 v6 探测失败时的行为一致，
    # 先由渲染器把 `-v6` 后缀的备用节点整条摘掉（含 proxy-groups 里的名字）。
    render_args=(
      --base "$workdir/base.yaml"
      --extra ${extraConfigFile}
      --nodes-raw "$workdir/nodes.json"
      --nodes-jq ${nodesJq}
      --tokens ${tokensFile}
      --addresses "$workdir/addresses.json"
      --out "$workdir/merged.yaml"
    )
    # 不再按 -v6 后缀剥节点：手机有原生 v6 时，v6 字面量节点（港）是唯一可用的
    # 境外出口，剥掉等于把港也退役。手机没有 v6 时它们健康检查不过，url-test /
    # fallback 自然会跳过 —— 代价只是一轮探测超时。
    mihomo-render "''${render_args[@]}"

    # 占位符替换。密码由 token_urlsafe 生成，只含 [A-Za-z0-9_-]，
    # sed 的替换串里不会出现需要转义的字符。
    hy2_pw="$(tr -d '\n' < "$workdir/hy2-password")"
    sed -e "s|__RELAY_HYSTERIA_PASSWORD__|$hy2_pw|g" \
      "$workdir/merged.yaml" > "$workdir/final.yaml"

    if grep -q "__RELAY_" "$workdir/final.yaml"; then
      echo "产物里仍有未替换的占位符，已中止" >&2
      exit 1
    fi

    # 移动端适配：剔掉只对 Linux 主机成立的字段。留在里面不会“稍微不对”——
    # 客户端要么起不来（绑不了 53）、要么多出不该有的监听面（0.0.0.0:10086）。
    #
    # IPv6 是另一类：不是“不成立”，而是“手机上会走一条桌面根本不存在的路”。
    # 节点域名同时有 A/AAAA，mihomo 在 ipv6:true 下优先 AAAA；手机有原生 v6，
    # 于是每条出站连接先去连节点的 v6。2026-10-31 在 shennong 上实测：
    #   ping6 <节点域名> 100% 丢包；curl -6 连节点 443 6s 超时；
    #   而同一条链路 v4 握手 0.44s，ping6 阿里 DNS 39ms（国内 v6 正常）。
    # 结果就是每个新连接先等一次 v6 超时再回落 v4，表现为“连不上/很慢”。
    # 桌面（zen14）没有可用 v6 出口，mihomo 出站清一色 v4，所以从没暴露。
    #
    # 用 `yq -P` 输出：不加 -P 时 yq 会把整份文档压成 flow style（rules 挤成
    # 一行超长数组），虽然仍是合法 YAML，但可读性差、部分解析器也不友好。
    # 同时改写到新文件，不用 -i：原地改写更容易丢掉原本的 block 排版。
    if [ "$raw" -eq 0 ]; then
      # 手机不跑 xray-client / tuic-client，那几条 `socks5 → 127.0.0.1:xxxx`
      # 的节点在手机上根本没有监听，留着只会让每次测速都白等一轮超时。
      # 原生节点（xhttp / reality）已经在节点清单里，不会被这条规则误删。
      #
      # 整条管线走 YAML → JSON → jq → YAML：剔除要同时改 proxies 和
      # proxy-groups[].proxies（名字是字符串，得先收集被删的名字集合），
      # yq 的表达式写不了这种关联，jq 写起来是直白的。
      # TUN 参数按 Android 的实际能力收窄：
      #   stack=system   FlClash 的 VpnService 上 system 栈对 UDP 处理不稳；
      #                  手机侧唯一能用的 hy2 节点走的就是 UDP，换成 gvisor。
      #   mtu=9000       桌面 mihomo 的默认值，Android 上远超链路 MTU（1500），
      #                  用户态栈要额外分片，长 RTT 链路上直接表现为 TLS 卡死。
      #   strict-route   只对 Linux 本机有意义，Android 上由 VpnService 决定路由。
      yq -o=json '
        del(.dns.listen) |
        del(.listeners) |
        del(.tun.auto-redirect) |
        del(.tun.auto-redirect-output-mark) |
        del(.tun.dns-hijack) |
        del(.tun.strict-route) |
        .tun.stack = "gvisor" |
        .tun.mtu = 1500 |
        .ipv6 = false |
        .dns.ipv6 = false |
        del(.dns."fake-ip-range6")
      ' "$workdir/final.yaml" > "$workdir/mobile.json"

      # 只有一类节点在手机上一定不可用：is_local —— 指向 127.0.0.1 的本机 socks
      # 上游（xray/tuic 客户端不跑在手机上）。
      #
      # v6 字面量节点（港-hy2-v6 / 港-vless-v6 等）刻意保留：手机有原生 v6 时它们
      # 是唯一不依赖美国线的境外出口。ipv6 仍是 false（域名节点继续只解析 A，
      # 避免 2026-10-31 记录过的「先等一次 AAAA 超时再回落 v4」），所以这类节点
      # 能不能用取决于 mihomo 是否允许直拨 v6 字面量 —— 实测不可用时把下面
      # `.ipv6 = false` 改成 true 即可，代价是域名节点回到 AAAA 优先。
      jq '
        def is_local: ((.server // "") | test("^(127\\.|::1$|localhost$)"));
        (.proxies // []) as $all
        | ($all | map(select(is_local)) | map(.name)) as $dropped
        | .proxies = ($all | map(select(is_local | not)))
        | (."proxy-groups" // []) as $groups
        # 美国组兜底：手机内核连不上这批美国节点（健康检查 alive:false /
        # delay:65535，而同节点经桌面 mihomo 只要 0.9–1.2s，手机原生
        # ping 该 IP 198ms 不丢包 —— 即网络可达、本机内核不可达）。
        # 组里没有任何可用成员时，url-test 会把请求钉在死的那个节点上，
        # 结果是 Google/ChatGPT 这类按地区分流的站点全部超时。
        # 用 fallback：按顺序取第一个健康成员；成员一律由组里已有的 filter 正则
        # 从剩余 proxies 算出（不写死节点名 —— 节点退役后写死的名字会变成悬空成员）。
        # 跨区兜底只取「香港」：它是唯一在手机上可能可用的非美国出口。
        | ($groups | map(select(.name == "美国")) | .[0]) as $us
        | ($groups | map(select(.name == "香港")) | .[0]) as $hk
        | (if $us == null then []
           else
             [ $all[] | select(is_local | not) | .name
               | select(test($us.filter // "^$")) ]
           end) as $usnames
        | (if $hk == null then []
           else
             [ $all[] | select(is_local | not) | .name
               | select(test($hk.filter // "^$")) ]
           end) as $hknames
        | ."proxy-groups" = ($groups | map(
            if has("proxies") then
              .proxies = [.proxies[] | select(. as $n | ($dropped | index($n) | not))]
              | (if (.proxies | length) == 0 then .proxies = ["DIRECT"] else . end)
            else . end
            | if .name == "美国" and ($usnames | length) > 0 then
                .type = "fallback"
                | del(."include-all", .filter, ."exclude-type")
                | .proxies = ($usnames + $hknames)
              else . end))
      ' "$workdir/mobile.json" > "$workdir/mobile.final.json"

      # 加密的手机端私有覆盖（miho-conf/mobile-extra.yaml.age）：rules 前置，
      # 其余键覆盖。放在这里而不是塞进 base，是为了不污染 --raw 产物。
      # 合并语义是浅覆盖，覆盖项不要写嵌套结构（如 dns），否则整段被顶掉。
      mobile_extra_rel="${mobileExtraRel}"
      if [ -n "$mobile_extra_rel" ]; then
        decrypt "$mobile_extra_rel" "$workdir/mobile-secret.yaml"
        yq -o=json '.' "$workdir/mobile-secret.yaml" > "$workdir/extra.secret.json"
        jq '
          . as $cfg
          | $extra[0] as $x
          | $cfg
          | .rules = (($x.rules // []) + ($cfg.rules // []))
          | . + ($x | del(.rules))
        ' --slurpfile extra "$workdir/extra.secret.json" \
          "$workdir/mobile.final.json" > "$workdir/mobile.secret.json"
        mv "$workdir/mobile.secret.json" "$workdir/mobile.final.json"
      fi

      idx=0
      for f in ''${mobile_extras[@]+"''${mobile_extras[@]}"}; do
        idx=$((idx + 1))
        yq -o=json '.' "$f" > "$workdir/extra.$idx.json"
        jq '
          . as $cfg
          | $extra[0] as $x
          | $cfg
          | .rules = (($x.rules // []) + ($cfg.rules // []))
          | . + ($x | del(.rules))
        ' --slurpfile extra "$workdir/extra.$idx.json" \
          "$workdir/mobile.final.json" > "$workdir/mobile.extra.json"
        mv "$workdir/mobile.extra.json" "$workdir/mobile.final.json"
      done

      yq -P "$workdir/mobile.final.json" > "$workdir/final.yaml"
      rm -f "$workdir/mobile.json" "$workdir/mobile.final.json"
    fi

    if [ "$to_stdout" -eq 1 ]; then
      cat "$workdir/final.yaml"
    else
      install -m 0600 "$workdir/final.yaml" "$out"
      {
        printf '已写出: %s\n' "$out"
        # 用 yq 计数：flow style 下的 "name": 与 block style 的 - name: 形式
        # 不同，用 grep 数会把同一批节点数成两倍或漏掉。
        printf '代理节点: %s 个\n' "$(yq -r '.proxies | length' "$workdir/final.yaml")"
        printf '代理组  : %s 个\n' "$(yq -r '."proxy-groups" | length' "$workdir/final.yaml")"
        printf '分流规则: %s 条\n' "$(yq -r '.rules | length' "$workdir/final.yaml")"
        printf '适配模式: %s\n' "$([ "$raw" -eq 1 ] && echo '原样（Linux）' || echo '移动端')"
        printf '注意: 含明文凭据且权限 600；对外投递请用 handoff\n'
        # 接收方要解密，先把取私钥的命令给出来。这不含敏感值，可直接转发。
        printf '取私钥: clan vars get zen14 handoff-key/secret-key\n'
      } >&2
    fi
  '';

  meta = {
    description = "导出完整 Clash 配置（与运行时同一渲染管线）";
    mainProgram = "clash-export";
  };
}
