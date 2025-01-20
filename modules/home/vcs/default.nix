{ config, lib, namespace, pkgs, ... }:
let cfg = config.${namespace}.vcs;
in {
  options.${namespace}.vcs = with lib; {
    user = mkOption {
      description = "Configure a default user for VCSs";
      default = null;
      type = types.nullOr (types.submodule {
        options = {
          name = mkOption {
            description = "User name";
            type = types.str;
          };
          email = mkOption {
            description = "User email";
            type = types.str;
          };
        };
      });
    };
  };

  config = {
    programs.git = {
      enable = true;
      extraConfig.pull.ff = "only";
      difftastic.enable = true;
      lfs.enable = true;
      ignores = [ ".direnv/" ".jj/" ];
    } // lib.optionalAttrs (cfg.user != null) {
      userName = cfg.user.name;
      userEmail = cfg.user.email;
    };

    programs.gitui.enable = true;

    programs.jujutsu = {
      enable = true;
      settings = {
        ui = {
          pager = "less -FXR";
          default-command = "log";
        };
      } // lib.optionalAttrs (cfg.user != null) { user = cfg.user; };
    };

    home.packages = with pkgs; [ lazyjj ];

    programs.starship.settings = {
      format =
        "$username$hostname$localip$shlvl$singularity$kubernetes$directory$vcsh$fossil_branch$fossil_metrics\${custom.jj}$git_branch$git_commit$git_state$git_metrics$git_status$hg_branch$pijul_channel$docker_context$package$c$cmake$cobol$daml$dart$deno$dotnet$elixir$elm$erlang$fennel$gleam$golang$guix_shell$haskell$haxe$helm$java$julia$kotlin$gradle$lua$nim$nodejs$ocaml$opa$perl$php$pulumi$purescript$python$quarto$raku$rlang$red$ruby$rust$scala$solidity$swift$terraform$typst$vlang$vagrant$zig$buf$nix_shell$conda$meson$spack$memory_usage$aws$gcloud$openstack$azure$nats$direnv$env_var$crystal$custom$sudo$cmd_duration$line_break$jobs$battery$time$status$os$container$shell$character";

      custom.jj = {
        command = ''
          jj log --revisions @ --limit 1 --no-graph --color always --template 'separate(" ", change_id.shortest(8), if(empty, "(empty)"))'
        '';
        detect_folders = [ ".jj" ];
        format = "on [$symbol]($style)$output ";
        unsafe_no_escape = true;
        style = "bold purple";
        symbol = "jj ";
      };
    };
  };
}
