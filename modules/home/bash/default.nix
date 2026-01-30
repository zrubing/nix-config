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
      fzf  # fuzzy finder
    ];

  };

}
