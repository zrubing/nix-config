{
  config,
  pkgs,
  namespace,
  ...
}: let
  # nix 管理的 MCP server 定义（纯 nix attrset，类型安全、可读、可注释）
  # 新增 server 只需在这里加条目，rebuild 后自动 merge 进各 agent 的 MCP 配置。
  # 注：含密钥的 server（如 context7/github PAT）放在 agenix secret 里，
  # 这里只放纯 nix 可表达的条目。
  nixMcpServers = {
    "chrome-devtools" = {
      # nix 包锁版本（flake 锁定），路径随 rebuild 自动更新，无需手动维护
      command = "${pkgs.${namespace}.chrome-devtools-mcp}/bin/chrome-devtools-mcp";
      args = [
        "-e"
        # NixOS 上 Puppeteer 下载的 Chrome-for-Testing 跑不了，必须指向系统 Chrome
        "${pkgs.unstable.google-chrome}/bin/google-chrome-stable"
      ];
    };
  };

  # 序列化为 JSON 供 activation 脚本 merge（替代 runCommand+jq 拼接）
  mcpServersJson = pkgs.writeText "nix-mcp-servers.json" (
    builtins.toJSON {mcpServers = nixMcpServers;}
  );
in {
  home.file = {
    ".claude/CLAUDE.md".source = ./CLAUDE.md;
  };

  # 把 nix 管理的 mcpServers merge 进各 agent 的 MCP 配置文件。
  # 合并顺序：用户手写条目 × agenix secret × nix 管理（后者优先级最高）。
  # 保留用户手写部分，所以用 activation + jq 而非整文件覆盖。
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
