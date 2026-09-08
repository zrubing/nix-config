{
  config,
  lib,
  pkgs,
  namespace,
  ...
}: let
  # 统一 MCP server 定义（pi / dsh / claude 共用源，见该文件头部注释）。
  # 新增或修改 server 只改 modules/home/mcp-servers/servers.nix 一处，
  # pi 侧由此处的 piServers 渲染，dsh 侧由 modules/home/dsh 的同一份渲染。
  # 密钥不写明文：pi 视图用 ${VAR} 引用（pi-mcp-adapter 对 env/headers/url
  # 插值），值来自 shell 的 ~/.config/default.env（sops 渲染）。
  mcpServers = import ../mcp-servers/servers.nix {inherit lib pkgs namespace;};

  # 序列化为 JSON 供 activation 脚本 merge（替代 runCommand+jq 拼接）
  mcpServersJson = pkgs.writeText "nix-mcp-servers.json" (
    builtins.toJSON {mcpServers = mcpServers.piServers;}
  );
in {
  home.file = {
    ".claude/CLAUDE.md".source = ./CLAUDE.md;
  };

  # 把 nix 管理的 mcpServers merge 进各 agent 的 MCP 配置文件。
  # 合并顺序：用户手写条目 × agenix secret × nix 管理（后者优先级最高）。
  # 保留用户手写部分，所以用 activation + jq 而非整文件覆盖。
  #
  # 2026-09 起 nix 源已覆盖全部 5 个 server（含 github/context7/zai/搜索），
  # 且密钥字段（env/args/headers）整体重写为 ${VAR} 引用，故 agenix secret 里的
  # 明文 mcpServers 不再出现在最终文件中，仅作「nix 源漏配时的兜底」保留。
  # 新增 server 的正确做法是改 modules/home/mcp-servers/servers.nix，不是改 secret。
  home.activation.mergeMcpConfigs = config.lib.dag.entryAfter ["writeBoundary"] ''
    # 设置 XDG_RUNTIME_DIR 默认值，避免在 systemd 服务中报错
    export XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

    jq_bin=${pkgs.jq}/bin/jq
    mv_bin=${pkgs.coreutils}/bin/mv
    mkdir_bin=${pkgs.coreutils}/bin/mkdir
    secret_path=${config.age.secrets."claude.settings.json".path}
    nix_mcp=${mcpServersJson}

    # 把 secret + nix 管理的 mcpServers merge 进目标文件（保留用户手写条目）
    merge_mcp_servers() {
      local target="$1"
      local target_dir
      target_dir=$(dirname "$target")

      "$mkdir_bin" -p "$target_dir"
      [[ -f "$target" ]] || echo '{}' > "$target"

      if [[ -f "$secret_path" ]]; then
        "$jq_bin" \
          --slurpfile secret "$secret_path" \
          --slurpfile nix "$nix_mcp" \
          '.mcpServers = ((.mcpServers // {}) * ($secret[0].mcpServers // {}) * ($nix[0].mcpServers // {}))' \
          "$target" > "$target.tmp" && "$mv_bin" "$target.tmp" "$target"
      else
        "$jq_bin" \
          --slurpfile nix "$nix_mcp" \
          '.mcpServers = ((.mcpServers // {}) * ($nix[0].mcpServers // {}))' \
          "$target" > "$target.tmp" && "$mv_bin" "$target.tmp" "$target"
      fi
    }

    merge_mcp_servers "$HOME/.claude.json"
    merge_mcp_servers "$HOME/.pi/agent/mcp.json"

    # eca：mcpServers 完全从 claude.json 同步
    eca_config="$HOME/.config/eca/config.json"
    "$mkdir_bin" -p "$(dirname "$eca_config")"
    [[ -f "$eca_config" ]] || echo '{}' > "$eca_config"
    "$jq_bin" --slurpfile claude "$HOME/.claude.json" \
      '.mcpServers = ($claude[0].mcpServers // {})' \
      "$eca_config" > "$eca_config.tmp" && "$mv_bin" "$eca_config.tmp" "$eca_config"
  '';
}
