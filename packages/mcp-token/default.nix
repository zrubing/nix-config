{ openbao, writeShellApplication }:

writeShellApplication {
  name = "mcp-token";

  runtimeInputs = [ openbao ];

  text = ''
    # 一次浏览器授权 → 一个文件。这是 MCP 家族唯一的凭据来源：
    # ci / db / agent-docs / loki / forgejo 全部由本地代理从这里取 token 注入。
    #
    # 为什么不是每个服务一个 token：Authelia 的 access token 只有 1 小时，
    # 客户端配置是静态的、没法刷新；OpenBao 的 periodic token 是 3 天滑动窗口，
    # 服务端在 TTL 掉到 2/3 以下时自动续期，正常只需登录一次。

    state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/mcp"
    token_file="''${MCP_TOKEN_FILE:-$state_dir/token}"
    role="''${MCP_LOGIN_ROLE:-mcp}"

    usage() {
      cat <<'EOF'
    用法：mcp-token <命令>

      login    浏览器授权一次，把拿到的 OpenBao token 写进 token 文件（0600）
      show     打印 token（脚本用；不要贴进聊天记录或提交）
      path     token 文件路径
      status   文件状态：存在性 / 大小 / 最后修改时间

    环境变量：
      MCP_TOKEN_FILE    覆盖 token 文件路径（默认 $XDG_STATE_HOME/mcp/token）
      MCP_LOGIN_ROLE    登录用的 OpenBao role（默认 mcp）
    EOF
    }

    case "''${1:-status}" in
      login)
        umask 077
        mkdir -p "$state_dir"
        tmp="$(mktemp "$state_dir/.token.XXXXXX")"
        trap 'rm -f "$tmp"' EXIT
        if ! bao login -method=oidc -role="$role" -token-only >"$tmp"; then
          echo "登录失败：bao login 返回非零" >&2
          exit 1
        fi
        if [ ! -s "$tmp" ]; then
          echo "登录失败：拿到的 token 为空" >&2
          exit 1
        fi
        chmod 600 "$tmp"
        mv "$tmp" "$token_file"
        trap - EXIT
        echo "已写入 $token_file（role=$role）。本地代理下一次请求即生效，无需重启。"
        ;;
      show)
        if [ ! -s "$token_file" ]; then
          echo "没有 token：先跑 mcp-token login" >&2
          exit 1
        fi
        cat "$token_file"
        ;;
      path)
        printf '%s\n' "$token_file"
        ;;
      status)
        if [ -s "$token_file" ]; then
          mode="$(stat -c '%a %U' "$token_file")"
          printf 'present %s bytes=%s mtime=%s mode=%s\n' \
            "$token_file" "$(stat -c %s "$token_file")" "$(stat -c %y "$token_file")" "$mode"
        else
          printf 'missing %s（跑 mcp-token login 生成）\n' "$token_file"
        fi
        ;;
      -h|--help|help)
        usage
        ;;
      *)
        usage
        exit 2
        ;;
    esac
  '';
}
