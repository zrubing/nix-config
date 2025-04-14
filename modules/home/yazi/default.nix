{
  config,
  lib,
  pkgs,
  namespace,
  system,
  inputs,
  ...
}:
with lib;
let
  cfg = config.${namespace}.yazi;
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
in
{
  options.${namespace}.yazi = with lib; {
    enable = mkEnableOption "Enable yazi";
  };

  config = mkIf cfg.enable {
    programs.yazi = {
      enable = true;
      package = (
        pkgs.writeScriptBin "yazi" ''
          #!/usr/bin/env zsh
          function y() {
            local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
            ${pkgs.yazi}/bin/yazi "$@" --cwd-file="$tmp"
            if cwd="$(command cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
              builtin cd -- "$cwd"
            fi
            rm -f -- "$tmp"
          }
          y
        ''
      );
      settings = {
        manager = {
          ratio = [
            1
            4
            3
          ];
          sort_by = "natural";
          sort_sensitive = true;
          sort_reverse = false;
          sort_dir_first = true;
          linemode = "none";
          show_hidden = true;
          show_symlink = true;
        };

        preview = {
          image_filter = "lanczos3";
          image_quality = 90;
          tab_size = 1;
          max_width = 600;
          max_height = 900;
          cache_dir = "";
          ueberzug_scale = 1;
          ueberzug_offset = [
            0
            0
            0
            0
          ];
        };

        tasks = {
          micro_workers = 5;
          macro_workers = 10;
          bizarre_retry = 5;
        };
      };
    };

    home.packages = with pkgs; [
      foot

      # https://yazi-rs.github.io/docs/installation/
      file
      ffmpeg
      jq
      fd
      ripgrep
      fzf
      zoxide
      imagemagick
      resvg
      xclip
      wl-clipboard
      xsel

    ];
    #https://github.com/hunkyburrito/xdg-desktop-portal-termfilechooser?tab=readme-ov-file#installation
    home.file."${config.xdg.configHome}/xdg-desktop-portal-termfilechooser/config".text = ''
      ### $XDG_CONFIG_HOME/xdg-desktop-portal-termfilechooser/config ###

      [filechooser]
      cmd=${pkgs-unstable.xdg-desktop-portal-termfilechooser}/share/xdg-desktop-portal-termfilechooser/yazi-wrapper.sh
      default_dir=$HOME
      env=TERMCMD=${pkgs.foot}/bin/foot -T "terminal-filechooser"
      env=VARIABLE2=VALUE2
    '';

  };
}
