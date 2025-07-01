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
