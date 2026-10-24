{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.agent-shell;

  # 默认屏蔽的路径：第三方凭据与密钥，与 agent 跑起来所需的配置无关。
  #
  # 刻意**不**屏蔽 ~/.dsh、~/.claude、~/.codex：那些是 agent 自己的运行凭据，
  # 屏蔽了 agent 直接启动失败，防护也就没意义了。
  #
  # 用 `/` 结尾的是目录，进 namespace 后变成空 tmpfs —— 原内容完全不可见。
  secretPaths = [
    ".aliyun" # 阿里云 AK/SK（work + self）
    ".aws"
    ".kube" # kubeconfig，含集群 admin 凭据
    ".docker" # registry 登录态
    ".config/gh" # GitHub token
    ".config/gcloud"
    ".netrc"
    ".gnupg" # GPG 私钥 → pass 全库
    ".local/share/password-store" # pass 密文（配合 GPG 可解）
    ".ssh" # SSH 私钥（--allow-ssh 可放行）
  ];

  # 系统级 secrets 目录：agent 本来也读不了（root/keys 组），但挂空更保险，
  # 免得哪天某个 secret 的 owner/group 配错。
  #
  # 注意挂的是 /run/agenix.d（父目录）而不是 /run/agenix：
  #   /run/agenix 是指向 /run/agenix.d/<generation> 的符号链接，而 generation
  #   目录是 root:keys 0700 —— 普通用户连 stat 都做不到。bwrap 解析到那个路径后
  #   会尝试创建挂载点，直接报 "Can't mkdir parents for /run/agenix.d/8"。
  #   挂父目录既绕开符号链接，也覆盖所有 generation。
  systemSecretPaths = [
    "/run/agenix.d"
    "/run/secrets.d"
  ];
in
{
  options.${namespace}.modules.agent-shell = {
    enable = lib.mkEnableOption "agent-shell：用 bubblewrap 屏蔽凭据后再启动 agent";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      (pkgs.writeShellScriptBin "agent-shell" ''
        set -euo pipefail

        allow_ssh=0
        argv=()
        for arg in "$@"; do
          case "$arg" in
            --allow-ssh) allow_ssh=1 ;;
            --help|-h)
              cat <<'EOF'
        agent-shell —— 在 bubblewrap 命名空间里启动 agent，屏蔽本机凭据。

        用法：
          agent-shell                      进入受限 bash
          agent-shell codex                受限执行 codex
          agent-shell --allow-ssh dsh      允许读 ~/.ssh（git push 等）后启动
          agent-shell --help               显示本帮助

        默认屏蔽（挂成空 tmpfs，进程完全看不到）：
          ~/.aliyun  ~/.aws  ~/.kube  ~/.docker  ~/.config/gh  ~/.config/gcloud
          ~/.netrc  ~/.gnupg  ~/.local/share/password-store  ~/.ssh
          /run/agenix  /run/secrets.d

        不屏蔽：~/.dsh ~/.claude ~/.codex（agent 自身运行依赖）。
        EOF
              exit 0
              ;;
            *) argv+=("$arg") ;;
          esac
        done

        args=(--dev-bind / / --die-with-parent --unshare-pid --share-net)

        # bwrap 不能在符号链接上挂载，所以要按类型分派：
        #   目录     → --tmpfs（空目录，原内容不可见）
        #   符号链接 → 解析真实路径后按类型再分：目录也 tmpfs，文件绑 /dev/null
        #              （如 ~/.netrc → /run/user/1000/agenix/netrc）
        #   普通文件 → 绑 /dev/null
        #
        # 若真实路径不可访问（如 /run/agenix.d/<gen> 是 root:keys 0700），
        # 退而挂它的父目录 —— 否则 bwrap 会尝试自己创建挂载点并报
        # "Can't mkdir parents"。
        hide() {
          local full="$1" real
          [ -e "$full" ] || return 0

          if [ -L "$full" ]; then
            real="$(readlink -f "$full" 2>/dev/null || true)"
            [ -n "$real" ] || return 0
            if [ -d "$real" ] && [ -x "$real" ]; then
              args+=(--tmpfs "$real")
            elif [ -d "$real" ]; then
              args+=(--tmpfs "$(dirname "$real")")
            elif [ -e "$real" ]; then
              args+=(--ro-bind /dev/null "$real")
            fi
          elif [ -d "$full" ]; then
            args+=(--tmpfs "$full")
          else
            args+=(--ro-bind /dev/null "$full")
          fi
        }

        for p in ${lib.escapeShellArgs secretPaths}; do
          if [ "$p" = ".ssh" ] && [ "$allow_ssh" -eq 1 ]; then
            continue
          fi
          hide "$HOME/$p"
        done

        for p in ${lib.escapeShellArgs systemSecretPaths}; do
          hide "$p"
        done

        if [ ''${#argv[@]} -eq 0 ]; then
          argv=("''${SHELL:-/run/current-system/sw/bin/bash}" -i)
        fi

        exec ${pkgs.bubblewrap}/bin/bwrap "''${args[@]}" -- "''${argv[@]}"
      '')
    ];
  };
}
