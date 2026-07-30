{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:

let
  cfg = config.${namespace}.kubefwd;

  enabledForwards = lib.filterAttrs (_: f: f.enable) cfg.forwards;

  # 收集所有需要转发的 namespace（去重）
  allNamespaces = lib.unique (
    lib.mapAttrsToList (_: f: f.namespace) enabledForwards
  );

  # 从各 forward 的 context 字段收集所有 context，不再需要笛卡尔搜索
  # The context is deliberately read from SOPS at runtime.  This keeps the
  # (potentially identifying) kube context out of the Nix store and Git.
  fwdStatic = lib.mapAttrsToList (_host: f: {
    inherit (f) service namespace ip contextSecret;
  }) enabledForwards;
in
{
  options.${namespace}.kubefwd = {
    enable = lib.mkEnableOption "kubefwd Kubernetes service port-forwarding daemon";

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "User to run kubefwd as. Must have read access to kubeconfig.";
    };

    sopsFile = lib.mkOption {
      type = lib.types.path;
      default = "${inputs.mysecrets}/secrets/env.yaml";
      description = "SOPS file containing the context secrets.";
    };

    forwards = lib.mkOption {
      default = { };
      description = ''
        Forward definitions keyed by hostname.
        Each entry maps a custom hostname to a Kubernetes Service via kubefwd.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Include this forward.";
            };

            ip = lib.mkOption {
              type = lib.types.str;
              example = "127.3.3.1";
              description = "Loopback IP reserved for this service.";
            };

            service = lib.mkOption {
              type = lib.types.str;
              example = "postgres";
              description = "Kubernetes Service name.";
            };

            namespace = lib.mkOption {
              type = lib.types.str;
              example = "beauty";
              description = "Kubernetes namespace containing the Service.";
            };

            contextSecret = lib.mkOption {
              type = lib.types.str;
              example = "kubefwd/contexts/sg";
              description = "SOPS key containing the Kubernetes context.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkIf (enabledForwards != { }) {
      sops.secrets = lib.listToAttrs (lib.mapAttrsToList (_host: f: {
        name = f.contextSecret;
        value.sopsFile = cfg.sopsFile;
      }) enabledForwards);

      # 将自定义 hostname 指向预留的 loopback IP
      networking.hosts = lib.foldlAttrs
        (
          acc: host: f:
          acc // { ${f.ip} = (acc.${f.ip} or [ ]) ++ [ host ]; }
        )
        { }
        enabledForwards;

      environment.systemPackages = [ pkgs.kubefwd ];

      # kubefwd 需要 writable hosts 文件（NixOS 的 /etc/hosts 是只读 symlink）
      systemd.tmpfiles.rules = [
        "d /run/kubefwd 0755 root root -"
      ];

      systemd.services.kubefwd = {
        description = "kubefwd port-forwarding daemon";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = [ pkgs.iproute2 ];
        serviceConfig = {
          ExecStartPre = [
            "+${pkgs.bash}/bin/bash -c 'mkdir -p /run/kubefwd && rm -f /run/kubefwd/hosts /run/kubefwd/fwdconf.json /run/kubefwd/entries.json /run/kubefwd/contexts && touch /run/kubefwd/hosts /run/kubefwd/entries.json /run/kubefwd/contexts'"
          ];
          ExecStart = let
            runner = pkgs.writeShellScript "kubefwd-runner" ''
              set -euo pipefail
              conf=/run/kubefwd/fwdconf.json
              ${lib.concatMapStringsSep "\n" (f: ''
                context="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.${f.contextSecret}.path} | ${pkgs.coreutils}/bin/tr -d '[:space:]')"
                ${pkgs.jq}/bin/jq -n --arg n "${f.service}.${f.namespace}.$${context}" --arg ip "${f.ip}" \
                  '{name: $n, ip: $ip}' >> /run/kubefwd/entries.json
                echo "$context" >> /run/kubefwd/contexts
              '') fwdStatic}
              ${pkgs.jq}/bin/jq -s '{baseUnreservedIP:"127.3.3.1",serviceConfigurations:.}' /run/kubefwd/entries.json > "$conf"
              exec ${pkgs.kubefwd}/bin/kubefwd svc \
                -n ${lib.concatStringsSep "," allNamespaces} \
                -z "$conf" $(while read -r c; do printf '%s' "-x $c "; done < /run/kubefwd/contexts) \
                --hosts-path /run/kubefwd/hosts -a
            '';
          in "+${runner}";
          Restart = "always";
          RestartSec = 10;
          User = cfg.user;
          Environment = "KUBECONFIG=/home/jojo/.kube/config-k0s.yml";
        };
      };
    }
  );
}
