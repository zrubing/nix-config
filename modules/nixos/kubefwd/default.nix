{
  config,
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

  # 生成 kubefwd IP 预留配置文件（JSON 是 YAML 子集，Go yaml 库可解析）
  # 格式参考：https://github.com/txn2/kubefwd/blob/master/example.fwdconf.yml
  fwdConfYaml =
    let
      serviceConfigurations = lib.mapAttrsToList (_host: f: {
        name = "${f.service}.${f.namespace}";
        ip = f.ip;
      }) enabledForwards;
    in
    pkgs.writeText "kubefwd-fwdconf.yml" (
      builtins.toJSON {
        baseUnreservedIP = "127.3.3.1";
        inherit serviceConfigurations;
      }
    );
in
{
  options.${namespace}.kubefwd = {
    enable = lib.mkEnableOption "kubefwd Kubernetes service port-forwarding daemon";

    context = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "hebe-jkt";
      description = "Kubernetes context to use (--context). Defaults to current-context.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "User to run kubefwd as. Must have read access to kubeconfig.";
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
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkIf (enabledForwards != { }) {
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
            "+${pkgs.bash}/bin/bash -c 'mkdir -p /run/kubefwd && rm -rf /run/kubefwd/hosts && touch /run/kubefwd/hosts'"
          ];
          ExecStart = lib.concatStringsSep " " (
            [ "${pkgs.kubefwd}/bin/kubefwd" "svc" ]
            ++ [ "-n ${lib.concatStringsSep "," allNamespaces}" ]
            ++ [ "-z ${fwdConfYaml}" ]
            ++ lib.optional (cfg.context != null) "-x ${cfg.context}"
            ++ [ "--hosts-path" "/run/kubefwd/hosts" "-a" ]
          );
          Restart = "always";
          RestartSec = 10;
          User = cfg.user;
          Environment = "KUBECONFIG=/home/jojo/.kube/config-k0s.yml";
        };
      };
    }
  );
}
