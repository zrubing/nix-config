{
  config,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.vcs;
in
{
  options.${namespace}.vcs = with lib; {
    user = mkOption {
      description = "Configure a default user for VCSs";
      default = null;
      type = types.nullOr (
        types.submodule {
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
        }
      );
    };
  };

  config = {
    programs.git = {
      enable = true;
      settings = {
        pull.ff = "only";
      };
      lfs.enable = true;
      ignores = [
        ".direnv/"
        ".jj/"
      ];
    }
    // lib.optionalAttrs (cfg.user != null) {
      settings = {

        user.email = cfg.user.email;
        user.name = cfg.user.name;
      };
    };

    programs.gitui.enable = true;
    programs.starship.settings = {

    };
  };
}
