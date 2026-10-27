{
  writeShellApplication,
  mihomoRender,
  agenix,
  coreutils,
  gnused,
  yq-go,
  lib,
  # 由调用方从 nixosConfigurations.<host>.config 注入 —— 包本身拿不到模块求值结果
  extraConfigFile,
  tokensFile,
  nodesJq,
  agenixRules,
  # 密文所在目录（flake input 的 store 路径）+ 仓库内相对路径
  secretsRoot,
  mihoConfRel,
  proxyNodesRel,
  relayPasswordRel,
  addressesRel,
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
      -h, --help         显示本帮助

    说明:
      · 节点与地址密文在本地现解，只在临时目录存在；
      · 与机器上运行中的配置同源（同一条渲染管线），不是另写一份；
      · 默认剔掉只对 Linux 主机成立的部分（见下） —— 手机端启动会不兼容；
      · 产物含明文密码，默认 0600。

    默认剔除的字段（--raw 保留）:
      dns.listen          手机非 root 绑不了 53，交给客户端自己管
      listeners           0.0.0.0 监听在手机上是多余暴露面
      tun.auto-redirect   Linux nftables 特性，Android 用 VpnService 不认
      tun.auto-redirect-output-mark   同上，skb mark 只对 Linux 本机有意义
      tun.dns-hijack      同上，由客户端接管
    EOF
    }

    out="exported.yaml"
    to_stdout=0
    raw=0

    while [ $# -gt 0 ]; do
      case "$1" in
        -o|--out)  out="$2"; shift 2 ;;
        --stdout)  to_stdout=1; shift ;;
        --raw)     raw=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
      esac
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

    # 四份输入：base 配置、节点清单、中转密码、敏感地址表
    decrypt ${mihoConfRel}      "$workdir/base.yaml"
    decrypt ${proxyNodesRel}    "$workdir/nodes.json"
    decrypt ${relayPasswordRel} "$workdir/hy2-password"
    decrypt ${addressesRel}     "$workdir/addresses.json"

    # 渲染（与 mihomo-prepare-config 同一条管线），密码仍是占位符
    mihomo-render \
      --base "$workdir/base.yaml" \
      --extra ${extraConfigFile} \
      --nodes-raw "$workdir/nodes.json" \
      --nodes-jq ${nodesJq} \
      --tokens ${tokensFile} \
      --addresses "$workdir/addresses.json" \
      --out "$workdir/merged.yaml"

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
    # 用 `yq -P` 输出：不加 -P 时 yq 会把整份文档压成 flow style（rules 挤成
    # 一行超长数组），虽然仍是合法 YAML，但可读性差、部分解析器也不友好。
    # 同时改写到新文件，不用 -i：原地改写更容易丢掉原本的 block 排版。
    if [ "$raw" -eq 0 ]; then
      yq -P '
        del(.dns.listen) |
        del(.listeners) |
        del(.tun.auto-redirect) |
        del(.tun.auto-redirect-output-mark) |
        del(.tun.dns-hijack)
      ' "$workdir/final.yaml" > "$workdir/mobile.yaml"
      mv "$workdir/mobile.yaml" "$workdir/final.yaml"
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
      } >&2
    fi
  '';

  meta = {
    description = "导出完整 Clash 配置（与运行时同一渲染管线）";
    mainProgram = "clash-export";
  };
}
