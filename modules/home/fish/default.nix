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

    home.file.".config/fish/functions/fish_prompt.fish".text = ''
      set -l nix_shell_info (
        if test -n "$IN_NIX_SHELL"
          echo -n "<nix-shell> "
        end
      )

    '';

    home.file."bin/nix-command-not-found" = {
      text = ''
        #!/usr/bin/env bash
        source ${pkgs.nix-index}/etc/profile.d/command-not-found.sh
        command_not_found_handle "$@"
      '';

      executable = true;
    };

    programs = {
      fish = {
        enable = true;
        interactiveShellInit = ''
          set -U fish_greeting
          set -U pure_symbol_prompt ">"
          set -U pure_color_mute "brgreen"
          set -U pure_enable_nixdevshell true
          set -U pure_enable_single_line_prompt true
          set -U fish_color_autosuggestion 586e75
          fish_add_path $HOME/bin
          fish_add_path $HOME/.local/bin/
          ${pkgs.mise}/bin/mise activate fish | source
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
