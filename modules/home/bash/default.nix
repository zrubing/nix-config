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
      initExtra = ''
        # Add to PATH
        export PATH="$HOME/bin:$PATH"
        export PATH="$HOME/.local/bin:$PATH"

        ${lib.optionalString (shellCfg.provider == "GLM") ''
          # 设置 Anthropic 环境变量（读取 SOPS 秘密文件）
          if [ -f ${config.sops.secrets."anthropic/base_url".path} ]; then
            export ANTHROPIC_BASE_URL="$(cat ${config.sops.secrets."anthropic/base_url".path} | xargs)"
          fi
          if [ -f ${config.sops.secrets."anthropic/api_key".path} ]; then
            export ANTHROPIC_API_KEY="$(cat ${config.sops.secrets."anthropic/api_key".path} | xargs)"
          fi

          export ANTHROPIC_MODEL="GLM-4.7"
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

        # 在 tmux 内启动时重置状态栏颜色（防止异常断开后颜色不恢复）
        if [ -n "$TMUX" ]; then
          tmux set-option -g status-style "bg=colour240,fg=white" 2>/dev/null
        fi

        # kubectl with auto SSH tunnel
        k() {
          if ! nc -z localhost 6443 2>/dev/null; then
            echo "Creating SSH tunnel to k0s via jump-box..."
            ssh -fN k0s-server
            sleep 1
          fi
          ${pkgs.kubectl}/bin/kubectl --kubeconfig ~/.kube/k0s.config "$@"
        }

        # Enable bash completion if available
        if ! shopt -oq posix; then
          if [ -f /usr/share/bash-completion/bash_completion ]; then
            . /usr/share/bash-completion/bash_completion
          elif [ -f /etc/bash_completion ]; then
            . /etc/bash_completion
          fi
        fi

        # Alt+T 打开默认编辑器编辑当前命令
        bind -x '"\et": edit-and-execute-command'

        # SSH 连接时修复 Ghostty TERM 类型 + tmux 状态栏变色
        ssh() (
          if [ -n "$TMUX" ]; then
            # 保存当前 tmux 状态栏颜色
            _TMUX_BG_ORIG="$(tmux show-option -g status-style 2>/dev/null | grep -o 'bg=colour[0-9]*')"
            # SSH 时设置红色状态栏
            tmux set-option -g status-style "bg=colour196,fg=white"

            # 无论如何退出都恢复颜色
            trap 'if [ -n "$_TMUX_BG_ORIG" ]; then
                    tmux set-option -g status-style "$_TMUX_BG_ORIG,fg=white"
                  else
                    tmux set-option -g status-style "bg=colour240,fg=white"
                  fi' EXIT
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
