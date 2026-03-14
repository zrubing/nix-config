{
  lib,
  config,
  pkgs,
  namespace,
  inputs,
  ...
}:

let
  shellCfg = config.${namespace}.shell;
in
{

  options.${namespace}.bash.enable = lib.mkEnableOption "Enable bash";

  config = lib.mkIf (shellCfg.enable == "bash") {

    programs.bash = {
      enable = true;

      # For login shells: ensure Maven sees the same JDK as `java`.
      profileExtra = ''
        if command -v java >/dev/null 2>&1; then
          export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
          export PATH="$JAVA_HOME/bin:$PATH"
        fi
      '';

      initExtra = ''
        # Add to PATH

        # 检查是否处于 POSIX 模式并关闭它
        # 这里可以添加条件判断，避免重复执行
        if [[ "$-" == *i* ]]; then
          set +o posix 2>/dev/null || true
        fi

        export PATH="$HOME/bin:$PATH"
        export PATH="$HOME/.local/bin:$PATH"

        # Make Maven follow the same JDK as `java` (so `mvn -v` shows Java 25).
        if command -v java >/dev/null 2>&1; then
          export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
          export PATH="$JAVA_HOME/bin:$PATH"
        fi

        ${lib.optionalString (shellCfg.provider == "GLM") ''
          # 设置 Anthropic 环境变量（读取 SOPS 秘密文件）
          if [ -f ${config.sops.secrets."anthropic/base_url".path} ]; then
            export ANTHROPIC_BASE_URL="$(cat ${config.sops.secrets."anthropic/base_url".path} | xargs)"
          fi
          if [ -f ${config.sops.secrets."anthropic/api_key".path} ]; then
            export ANTHROPIC_API_KEY="$(cat ${config.sops.secrets."anthropic/api_key".path} | xargs)"
          fi

          export ANTHROPIC_MODEL="GLM-5"
        ''}

        ${lib.optionalString (shellCfg.provider == "MiniMax") ''
          # 设置 Minimax 环境变量（读取 SOPS 秘密文件）
          if [ -f ${config.sops.secrets."minimax-coding/base_url".path} ]; then
            export ANTHROPIC_BASE_URL="$(cat ${config.sops.secrets."minimax-coding/base_url".path} | xargs)"
          fi
          if [ -f ${config.sops.secrets."minimax-coding/api_key".path} ]; then
            export ANTHROPIC_API_KEY="$(cat ${config.sops.secrets."minimax-coding/api_key".path} | xargs)"
          fi

          export ANTHROPIC_MODEL="MiniMax-M2.1"
        ''}

        ${lib.optionalString (shellCfg.provider == "Qwen") ''
          # 设置 Qwen 环境变量（读取 SOPS 秘密文件）
          if [ -f ${config.sops.secrets."qwen/base_url".path} ]; then
            export ANTHROPIC_BASE_URL="$(cat ${config.sops.secrets."qwen/base_url".path} | xargs)"
          fi
          if [ -f ${config.sops.secrets."qwen/api_key".path} ]; then
            export ANTHROPIC_AUTH_TOKEN="$(cat ${config.sops.secrets."qwen/api_key".path} | xargs)"
          fi

          export ANTHROPIC_MODEL="qwen3-max-2026-01-23"
        ''}

        ${lib.optionalString (shellCfg.provider == "Volc") ''
          # 设置 Volc 环境变量（读取 SOPS 秘密文件）
          if [ -f ${config.sops.secrets."volc-coding/base_url".path} ]; then
            export ANTHROPIC_BASE_URL="$(cat ${config.sops.secrets."volc-coding/base_url".path} | xargs)"
          fi
          if [ -f ${config.sops.secrets."volc-coding/api_key".path} ]; then
            export ANTHROPIC_API_KEY="$(cat ${config.sops.secrets."volc-coding/api_key".path} | xargs)"
          fi
          if [ -f ${config.sops.secrets."volc-coding/model".path} ]; then
            export ANTHROPIC_MODEL="$(cat ${config.sops.secrets."volc-coding/model".path} | xargs)"
          fi
        ''}

        export API_TIMEOUT_MS=3000000
        export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

        if [ -f ${config.sops.secrets."woodpecker/server".path} ]; then
          export WOODPECKER_SERVER="$(cat ${config.sops.secrets."woodpecker/server".path} | xargs)"
          export WOODPECKER_TOKEN="$(cat ${config.sops.secrets."woodpecker/token".path} | xargs)"
        fi

        if [ -f ${config.sops.secrets."zot/username".path} ]; then
          export ZOT_REGISTRY_USERNAME="$(cat ${config.sops.secrets."zot/username".path} | xargs)"
          export ZOT_REGISTRY_PASSWORD="$(cat ${config.sops.secrets."zot/password".path} | xargs)"
        fi



        # Enable bash completion if available
        if ! shopt -oq posix; then
          if [ -f /usr/share/bash-completion/bash_completion ]; then
            . /usr/share/bash-completion/bash_completion
          elif [ -f /etc/bash_completion ]; then
            . /etc/bash_completion
          fi
        fi

        # Alt+T 打开默认编辑器编辑当前命令
        if [[ "$-" == *i* ]] && type bind >/dev/null 2>&1; then
          bind -x '"\et": edit-and-execute-command'
        fi

        # SSH 连接时修复 Ghostty TERM 类型 + 自动重命名 tmux 窗口
        ssh() (
          if [ -n "$TMUX" ]; then
            # 提取主机名用于窗口命名
            local hostname=$(echo "$@" | sed 's/.*@\([^ ]*\).*/\1/')
            # 退出时恢复窗口名
            trap 'tmux rename-window "bash" 2>/dev/null' EXIT
            # 重命名窗口为 ssh:hostname
            tmux rename-window "ssh:$hostname" 2>/dev/null
          fi

          if [ "$TERM" = "xterm-ghostty" ]; then
            TERM=xterm-256color command ssh "$@"
          else
            command ssh "$@"
          fi
        )
      '';

      # Add useful bash aliases
      shellAliases = {
        ll = "ls -alF";
        la = "ls -A";
        l = "ls -CF";
        grep = "grep --color=auto";
        sudo = "sudo -A";  # 默认使用 GUI askpass
      };

    };

    # Install bash useful packages
    home.packages = with pkgs; [
      bash-completion
    ];

    # Enable fzf with bash integration
    programs.fzf = {
      enable = true;
      enableBashIntegration = true;
      defaultOptions = [
        "--height=40%"
        "--layout=reverse"
        "--inline-info"
      ];
    };

    # zoxide - smarter cd command (z replacement)
    programs.zoxide = {
      enable = true;
      enableBashIntegration = true;
    };

    # atuin - enhanced shell history
    programs.atuin = {
      enable = true;
      enableBashIntegration = true;
      settings = {
        auto_sync = false;
        sync_frequency = "5m";
        search_mode = "fuzzy";
        keymap_mode = "auto";
      };
    };

    # starship - modern prompt
    programs.starship = {
      enable = true;
      enableBashIntegration = true;
      settings = {
        format = "$username@$hostname:$directory$git_branch$character ";
        character = {
          success_symbol = "[➜](bold green)";
          error_symbol = "[➜](bold red)";
        };
        directory.style = "bold blue";
      };
    };

  };

}
