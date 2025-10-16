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


          # 设置 Anthropic 环境变量（读取 SOPS 秘密文件）
          if test -f ${config.sops.secrets."anthropic/base_url".path}
            set -gx ANTHROPIC_BASE_URL (cat ${config.sops.secrets."anthropic/base_url".path} | string trim)
          end
          if test -f ${config.sops.secrets."anthropic/api_key".path}
            set -gx ANTHROPIC_API_KEY (cat ${config.sops.secrets."anthropic/api_key".path} | string trim)
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
