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

  # systemd unit 名里的 slug：hostname 中的 "." 换成 "-"
  slug = host: lib.replaceStrings [ "." ] [ "-" ] host;

  # 每个 forward 条目一个 unit：精确限定 context + namespace + service，
  # 避免单进程 -n/-x 笛卡尔积导致整个 namespace 的服务全被转发。
  # 各 unit 使用独立的 fwdconf/hosts 文件：kubefwd 的 hosts 锁是进程内的，
  # 多进程共享同一 hosts 文件会互相覆盖条目。
  # context 仍从 SOPS 运行时读取，避免 kube context 进入 Nix store 和 Git。
  mkForwardService =
    host: f:
    let
      key = slug host;
    in
    {
      description = "kubefwd port-forward for ${f.service}.${f.namespace} (${host}); hosts: /run/kubefwd/hosts-${key}";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      # kubeconfig 的 user 是 exec 插件（kubectl oidc-login get-token），client-go 会
      # 从 PATH 找 kubectl，kubectl 再找 kubectl-oidc_login（由 kubelogin-oidc 提供）。
      path = [
        pkgs.iproute2
        pkgs.kubectl
        pkgs.kubelogin-oidc
      ];
      serviceConfig = {
        ExecStartPre = [
          "+${pkgs.bash}/bin/bash -c 'mkdir -p /run/kubefwd && rm -f /run/kubefwd/fwdconf-${key}.json /run/kubefwd/hosts-${key} && touch /run/kubefwd/hosts-${key}'"
        ];
        ExecStart = let
          runner = pkgs.writeShellScript "kubefwd-runner-${key}" ''
            set -euo pipefail
            key="${key}"
            dir=/run/kubefwd
            context="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.${f.contextSecret}.path} | ${pkgs.coreutils}/bin/tr -d '[:space:]')"
            ${pkgs.jq}/bin/jq -n \
              --arg n "${f.service}.${f.namespace}.$context" \
              --arg ip "${f.ip}" \
              '{baseUnreservedIP:"127.3.3.1",serviceConfigurations:[{name:$n,ip:$ip}]}' \
              > "$dir/fwdconf-$key.json"
            exec ${pkgs.kubefwd}/bin/kubefwd svc \
              -n ${f.namespace} \
              -x "$context" \
              -f "metadata.name=${f.service}" \
              -z "$dir/fwdconf-$key.json" \
              --hosts-path "$dir/hosts-$key" \
              -a
          '';
        in "+${runner}";
        Restart = "always";
        RestartSec = 10;
        User = cfg.user;
        # KUBECONFIG/HOME 都指向 jojo：exec 插件的 OIDC token 缓存在
        # $HOME/.kube/cache/oidc-login，root 下无缓存会触发交互式登录。
        # kubelogin 对已存在的缓存文件是原地覆写，属主仍是 jojo。
        Environment = [
          "KUBECONFIG=/home/jojo/.kube/config-k0s.yml"
          "HOME=/home/jojo"
        ];
      };
    };
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

      systemd.services = lib.mapAttrs' (
        host: f: lib.nameValuePair "kubefwd-${slug host}" (mkForwardService host f)
      ) enabledForwards;
    }
  );
}
