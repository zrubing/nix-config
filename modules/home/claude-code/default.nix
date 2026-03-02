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
    ".claude/settings.json".source = mergedSettings;
  };

  home.activation = {
    mergeClaudeMcpConfig = config.lib.dag.entryAfter ["writeBoundary"] ''
      # 设置 XDG_RUNTIME_DIR 默认值，避免在 systemd 服务中报错
      export XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

      conf=$HOME/.claude.json

      # 如果主配置不存在，先写一个空对象进去
      if [[ ! -f $conf ]]; then
        echo '{}' > "$conf"
      fi

      # 合并 MCP 配置到 ~/.claude.json
      # 先合并 secret 中的配置，再合并 chrome-devtools（需要 nix store 路径）
      if [[ -f ${config.age.secrets."claude.settings.json".path} ]]; then
        ${pkgs.jq}/bin/jq \
          --slurpfile secret ${config.age.secrets."claude.settings.json".path} \
          --slurpfile mcp ${mergedSettings} \
          '.mcpServers = ((.mcpServers // {}) * ($secret[0].mcpServers // {}) * ($mcp[0].mcpServers // {}))' \
          "$conf" > /tmp/.claude.json.tmp && \
        ${pkgs.coreutils}/bin/mv /tmp/.claude.json.tmp "$conf"
      else
        ${pkgs.jq}/bin/jq --slurpfile mcp ${mergedSettings} \
          '.mcpServers = ((.mcpServers // {}) * ($mcp[0].mcpServers // {}))' \
          "$conf" > /tmp/.claude.json.tmp && \
        ${pkgs.coreutils}/bin/mv /tmp/.claude.json.tmp "$conf"
      fi

      # 将 MCP 配置也替换到 ECA 配置中
      eca_config="$HOME/.config/eca/config.json"

      # 如果 ECA 配置不存在，创建一个基础配置
      if [[ ! -f "$eca_config" ]]; then
        ${pkgs.coreutils}/bin/mkdir -p "$HOME/.config/eca"
        echo '{}' > "$eca_config"
      fi

      # 如果 Claude 配置存在且包含 MCP 服务器配置，则完全替换到 ECA 配置
      if [[ -f "$conf" ]]; then
        ${pkgs.jq}/bin/jq --slurpfile claude "$conf" \
          '.mcpServers = ($claude[0].mcpServers // {})' \
          "$eca_config" > "$eca_config.tmp" && \
        ${pkgs.coreutils}/bin/mv "$eca_config.tmp" "$eca_config"
      fi
    '';
  };
}
