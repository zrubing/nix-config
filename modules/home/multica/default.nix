{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.multica;
in
{
  options.${namespace}.modules.multica = with lib; {
    enable = mkEnableOption "Enable Multica CLI multi-cluster management tool";

    desktop.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Multica Desktop GUI (${namespace}.multica-desktop)";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      home.packages = [
        pkgs.${namespace}.multica
      ];

      home.file.".multica/config.json" = {
        force = true;
        text = builtins.toJSON {
          server_url = "http://multica-api.local";
          app_url = "http://multica.local";
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.desktop.enable) {
      home.packages = [
        pkgs.${namespace}.multica-desktop
      ];

      home.file.".multica/desktop.json" = {
        force = true;
        text = builtins.toJSON {
          schemaVersion = 1;
          apiUrl = "http://multica-api.local";
          wsUrl = "ws://multica-api.local/ws";
          appUrl = "http://multica.local";
        };
      };
    })
  ];
}
