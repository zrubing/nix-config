{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.mysql-proxy;
  mysecrets = inputs.mysecrets;

  enabledProxies = lib.filterAttrs (_name: proxy: proxy.enable) cfg.proxies;
in
{
  options.${namespace}.mysql-proxy = {
    enable = lib.mkEnableOption "local MySQL TCP proxies backed by socat";

    proxies = lib.mkOption {
      default = { };
      description = ''
        Local MySQL proxy definitions.

        Keep local bind addresses in Nix for readability, and keep the real
        upstream RDS address in sops via targetHostSecret. Hostname mapping is
        intentionally left to the host networking module.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule ({ name, ... }: {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to create this proxy service.";
            };

            autoStart = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to start this proxy at boot. Use false for dangerous prod-write endpoints.";
            };

            listenIp = lib.mkOption {
              type = lib.types.str;
              example = "127.0.0.2";
              description = "Loopback IP to bind locally. Linux treats 127.0.0.0/8 as loopback.";
            };

            listenPort = lib.mkOption {
              type = lib.types.port;
              default = 3306;
              description = "Local TCP port to listen on.";
            };


            targetHostSecret = lib.mkOption {
              type = lib.types.str;
              example = "mysql_proxy/test/target_host";
              description = "sops key containing the upstream MySQL host.";
            };

            targetPort = lib.mkOption {
              type = lib.types.port;
              default = 3306;
              description = "Upstream MySQL port.";
            };

            sopsFile = lib.mkOption {
              type = lib.types.path;
              default = "${mysecrets}/secrets/env.yaml";
              defaultText = lib.literalExpression ''"\${inputs.mysecrets}/secrets/env.yaml"'';
              description = "Encrypted sops YAML file containing targetHostSecret.";
            };
          };
        })
      );
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.socat ];


    sops.secrets = lib.mapAttrs' (
      _name: proxy:
      lib.nameValuePair proxy.targetHostSecret {
        inherit (proxy) sopsFile;
        owner = "root";
        group = "root";
        mode = "0400";
      }
    ) enabledProxies;

    systemd.services = lib.mapAttrs' (
      name: proxy:
      lib.nameValuePair "mysql-proxy-${name}" {
        description = "Local MySQL proxy ${name}";

        wantedBy = lib.optionals proxy.autoStart [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
          "run-secrets.d.mount"
        ];
        requires = [ "run-secrets.d.mount" ];

        serviceConfig = {
          Type = "simple";
          Restart = "always";
          RestartSec = "3s";
          NoNewPrivileges = true;
          PrivateTmp = true;
        };

        script = ''
          set -euo pipefail

          target_host="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.${proxy.targetHostSecret}.path} | ${pkgs.coreutils}/bin/tr -d '[:space:]')"

          if [ -z "$target_host" ]; then
            echo "empty target host for mysql proxy ${name}" >&2
            exit 1
          fi

          exec ${pkgs.socat}/bin/socat \
            TCP-LISTEN:${toString proxy.listenPort},bind=${proxy.listenIp},fork,reuseaddr \
            TCP:"$target_host":${toString proxy.targetPort}
        '';
      }
    ) enabledProxies;
  };
}
