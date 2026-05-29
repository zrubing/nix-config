{
  config,
  pkgs,
  inputs,
  system,
  ...
}:
let
  username = config.snowfallorg.user.name;
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit system;
    config.allowUnfree = true;
  };

  # 合并后的 settings.json
  mergedSettings = pkgs.runCommand "claude-settings.json" {
    nativeBuildInputs = [ pkgs.jq ];
  } ''
    # 添加 chrome-devtools 配置
    ${pkgs.jq}/bin/jq \
      --arg chrome "${pkgs-unstable.google-chrome}/bin/google-chrome-stable" \
      '.mcpServers["chrome-devtools"] = {
        "command": "npx",
        "args": [
          "chrome-devtools-mcp@latest",
          "-e",
          $chrome
        ]
      }' \
      ${./settings.json} > $out
  '';
in
{
  home.file = {
    ".claude/CLAUDE.md".source = ./CLAUDE.md;
    # ".claude/settings.json".source = mergedSettings;
  };

  home.activation = {
    mergeClaudeMcpConfig = config.lib.dag.entryAfter ["writeBoundary"] ''
      # 设置 XDG_RUNTIME_DIR 默认值，避免在 systemd 服务中报错
      export XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

      jq_bin=${pkgs.jq}/bin/jq
      mv_bin=${pkgs.coreutils}/bin/mv
      mkdir_bin=${pkgs.coreutils}/bin/mkdir
      secret_path=${config.age.secrets."claude.settings.json".path}
      merged_settings=${mergedSettings}

      write_mcp_servers_from_sources() {
        local target="$1"
        local target_dir
        target_dir=$(dirname "$target")

        "$mkdir_bin" -p "$target_dir"

        if [[ ! -f "$target" ]]; then
          echo '{}' > "$target"
        fi

        if [[ -f "$secret_path" ]]; then
          "$jq_bin" \
            --slurpfile secret "$secret_path" \
            --slurpfile mcp "$merged_settings" \
            '.mcpServers = ((.mcpServers // {}) * ($secret[0].mcpServers // {}) * ($mcp[0].mcpServers // {}))' \
            "$target" > "$target.tmp" && \
          "$mv_bin" "$target.tmp" "$target"
        else
          "$jq_bin" \
            --slurpfile mcp "$merged_settings" \
            '.mcpServers = ((.mcpServers // {}) * ($mcp[0].mcpServers // {}))' \
            "$target" > "$target.tmp" && \
          "$mv_bin" "$target.tmp" "$target"
        fi
      }

      sync_mcp_servers_from_claude() {
        local target="$1"
        local target_dir
        target_dir=$(dirname "$target")

        "$mkdir_bin" -p "$target_dir"

        if [[ ! -f "$target" ]]; then
          echo '{}' > "$target"
        fi

        "$jq_bin" --slurpfile claude "$conf" \
          '.mcpServers = ($claude[0].mcpServers // {})' \
          "$target" > "$target.tmp" && \
        "$mv_bin" "$target.tmp" "$target"
      }

      conf=$HOME/.claude.json
      pi_mcp_config=$HOME/.pi/agent/mcp.json
      eca_config=$HOME/.config/eca/config.json

      write_mcp_servers_from_sources "$conf"
      write_mcp_servers_from_sources "$pi_mcp_config"
      sync_mcp_servers_from_claude "$eca_config"
    '';
  };
}
