{
  lib,
  config,
  pkgs,
  namespace,
  inputs,
  ...
}:

let
  cfg = config.${namespace}.fish;
in
{

  options.${namespace}.fish = {
    enable = lib.mkEnableOption "Enable fish";
    provider = lib.mkOption {
      type = lib.types.enum [ "GLM" "MiniMax" "Qwen" "Volc" ];
      default = "glm";
      description = "AI provider to use (GLM, MiniMax, Qwen, or Volc)";
    };
  };

  config = lib.mkIf cfg.enable {

    programs = {
      fish = {
        enable = true;
        interactiveShellInit = ''
          set --universal pure_show_system_time true
          set --universal pure_symbol_ssh_prefix "ssh-->"

          fish_add_path $HOME/bin
          fish_add_path $HOME/.local/bin/

          ${lib.optionalString (cfg.provider == "GLM") ''
            # 设置 Anthropic 环境变量（读取 SOPS 秘密文件）
            if test -f ${config.sops.secrets."anthropic/base_url".path}
              set -gx ANTHROPIC_BASE_URL (cat ${config.sops.secrets."anthropic/base_url".path} | string trim)
            end
            if test -f ${config.sops.secrets."anthropic/api_key".path}
              set -gx ANTHROPIC_API_KEY (cat ${config.sops.secrets."anthropic/api_key".path} | string trim)
            end

            set -gx ANTHROPIC_MODEL GLM-4.7
          ''}

          ${lib.optionalString (cfg.provider == "MiniMax") ''
            # 设置 Minimax 环境变量（读取 SOPS 秘密文件）
            if test -f ${config.sops.secrets."minimax-coding/base_url".path}
              set -gx ANTHROPIC_BASE_URL (cat ${config.sops.secrets."minimax-coding/base_url".path} | string trim)
            end
            if test -f ${config.sops.secrets."minimax-coding/api_key".path}
              set -gx ANTHROPIC_API_KEY (cat ${config.sops.secrets."minimax-coding/api_key".path} | string trim)
            end

            set -gx ANTHROPIC_MODEL MiniMax-M2.1
          ''}

          ${lib.optionalString (cfg.provider == "Qwen") ''
            # 设置 Qwen 环境变量（读取 SOPS 秘密文件）
            if test -f ${config.sops.secrets."qwen/base_url".path}
              set -gx ANTHROPIC_BASE_URL (cat ${config.sops.secrets."qwen/base_url".path} | string trim)
            end
            if test -f ${config.sops.secrets."qwen/api_key".path}
              set -gx ANTHROPIC_AUTH_TOKEN (cat ${config.sops.secrets."qwen/api_key".path} | string trim)
            end

            set -gx ANTHROPIC_MODEL qwen3-max-2026-01-23
          ''}

          ${lib.optionalString (cfg.provider == "Volc") ''
            # 设置 Volc 环境变量（读取 SOPS 秘密文件）
            if test -f ${config.sops.secrets."volc-coding/base_url".path}
              set -gx ANTHROPIC_BASE_URL (cat ${config.sops.secrets."volc-coding/base_url".path} | string trim)
            end
            if test -f ${config.sops.secrets."volc-coding/api_key".path}
              set -gx ANTHROPIC_API_KEY (cat ${config.sops.secrets."volc-coding/api_key".path} | string trim)
            end
            if test -f ${config.sops.secrets."volc-coding/model".path}
              set -gx ANTHROPIC_MODEL (cat ${config.sops.secrets."volc-coding/model".path} | string trim)
            end
          ''}

          set -gx API_TIMEOUT_MS 3000000
          set -gx CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC 1

          # kubectl with auto SSH tunnel
          function k
            if not nc -z localhost 6443 2>/dev/null
              echo "Creating SSH tunnel to k0s via jump-box..."
              ssh -fN k0s-server
              sleep 1
            end
            ${pkgs.kubectl}/bin/kubectl --kubeconfig ~/.kube/k0s.config $argv
          end

        '';
        plugins = [
          {
            name = "pure";
            src = pkgs.fishPlugins.pure.src;
          }
          {
            name = "fzf";
            src = pkgs.fishPlugins.fzf.src;
          }
          # Manually packaging and enable a plugin
          {
            name = "z";
            src = pkgs.fetchFromGitHub {
              owner = "jethrokuan";
              repo = "z";
              rev = "e0e1b9dfdba362f8ab1ae8c1afc7ccf62b89f7eb";
              sha256 = "0dbnir6jbwjpjalz14snzd3cgdysgcs3raznsijd6savad3qhijc";
            };
          }
        ];

      };

    };

  };

}
