{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:

let
  cfg = config.${namespace}.tcp-forward;
  mysecrets = inputs.mysecrets;

  enabledForwards = lib.filterAttrs (_: f: f.enable) cfg.forwards;

  # Build networking.hosts from all enabled forwards.
  # Multiple forwards on the same listenIp merge their hostnames.
  hostsForwards =
    forwards:
    lib.foldlAttrs
      (
        acc: _name: f:
        if f.hostnames == [ ] then
          acc
        else
          acc // { ${f.listenIp} = (acc.${f.listenIp} or [ ]) ++ f.hostnames; }
      )
      { }
      forwards;

  # All forward secrets are root-only, single sopsFile.
  mkSecretEntry = _key: {
    inherit (cfg) sopsFile;
    owner = "root";
    group = "root";
    mode = "0400";
  };
in

{
  options.${namespace}.tcp-forward = {
    enable = lib.mkEnableOption ''
      Local TCP forwards with sops-managed upstreams.

      Supports two modes per forward:
      - direct:     socat TCP proxy to a network-reachable upstream (RDS, etc.).
      - ssh-tunnel: ssh -L via a bastion; the bastion/target addresses live in
                    a sops-rendered ssh config so they never appear in the nix
                    repo, the systemd unit, or the process list.
    '';

    sopsFile = lib.mkOption {
      type = lib.types.path;
      default = "${mysecrets}/secrets/env.yaml";
      defaultText = lib.literalExpression ''"\${inputs.mysecrets}/secrets/env.yaml"'';
      description = "sops YAML file containing all forward secrets.";
    };

    forwards = lib.mkOption {
      default = { };
      description = "Forward definitions keyed by a stable name.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Create this forward service.";
              };

              autoStart = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Start at boot. Use false for dangerous prod-write endpoints.";
              };

              listenIp = lib.mkOption {
                type = lib.types.str;
                example = "127.0.0.2";
                description = "Loopback IP to bind locally (Linux treats 127.0.0.0/8 as loopback).";
              };

              listenPort = lib.mkOption {
                type = lib.types.port;
                description = "Local TCP port to listen on.";
              };

              hostnames = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [ "test.mysql.local" ];
                description = "Hostnames mapped to listenIp via networking.hosts.";
              };

              mode = lib.mkOption {
                type = lib.types.enum [
                  "direct"
                  "ssh-tunnel"
                ];
                default = "direct";
                description = ''
                  <literal>direct</literal>: socat to upstream host:port.
                  <literal>ssh-tunnel</literal>: ssh -L through a bastion.
                '';
              };

              # ---- direct mode ----
              upstreamHostSecret = lib.mkOption {
                type = lib.types.str;
                example = "mysql_proxy/test/target_host";
                description = "sops key holding the upstream host (direct mode).";
              };

              upstreamPort = lib.mkOption {
                type = lib.types.port;
                description = "Upstream TCP port (direct mode).";
              };

              # ---- ssh-tunnel mode ----
              ssh = {
                jumpHostSecret = lib.mkOption {
                  type = lib.types.str;
                  description = "sops key holding the bastion address (ssh-tunnel).";
                };
                jumpUser = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "SSH user for the bastion. Usually non-sensitive; empty = ssh default.";
                };
                targetHostSecret = lib.mkOption {
                  type = lib.types.str;
                  description = "sops key holding the internal target host behind the bastion (ssh-tunnel).";
                };
                targetPort = lib.mkOption {
                  type = lib.types.port;
                  description = "Target port behind the bastion (ssh-tunnel).";
                };
                identityFile = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "Path to SSH private key. Required under systemd (no agent).";
                };
                # autossh 探活端口：autossh 通过它会主动建立一条额外的 ssh 连接来回
                # 探测链路活性，能发现“进程活着但 TCP 半开”的僵尸连接——这正是裸
                # `ssh + Restart=always` 检测不到的。默认 0=禁用探活，退化为裸 ssh
                # 行为；跨公网跳板机建议设为非 0。
                monitoringPort = lib.mkOption {
                  type = lib.types.port;
                  default = 0;
                  description = ''
                    autossh monitoring port. 0 disables active probing (falls back to
                    ServerAliveInterval only). For cross-internet bastions, set to a
                    non-zero port so autossh can detect half-open connections.
                  '';
                };
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.socat
      pkgs.openssh
    ];

    # networking.hosts entries are generated automatically.
    networking.hosts = hostsForwards enabledForwards;

    # ---- declare every secret we will read/render ----
    sops.secrets =
      let
        directSecrets = lib.mapAttrs' (
          _name: f: lib.nameValuePair f.upstreamHostSecret (mkSecretEntry f.upstreamHostSecret)
        ) (lib.filterAttrs (_: f: f.mode == "direct") enabledForwards);

        sshSecrets = lib.concatMapAttrs (
          _name: f:
          {
            ${f.ssh.jumpHostSecret} = mkSecretEntry f.ssh.jumpHostSecret;
            ${f.ssh.targetHostSecret} = mkSecretEntry f.ssh.targetHostSecret;
          }
        ) (lib.filterAttrs (_: f: f.mode == "ssh-tunnel") enabledForwards);
      in
      directSecrets // sshSecrets;

    # ---- render ssh config files (one per ssh-tunnel forward) ----
    # The real bastion/target addresses only ever exist in these 0400 files at
    # runtime; the nix repo, the systemd unit, and `ps` only ever see the alias
    # "tcp-forward-<name>". This is the concrete value of "sops template is safer".
    sops.templates =
      let
        sshForwards = lib.filterAttrs (_: f: f.mode == "ssh-tunnel") enabledForwards;
        ph = config.sops.placeholder;
      in
      lib.mapAttrs'
        (
          name: f:
          lib.nameValuePair "tcp-forward-${name}.sshconf" {
            owner = "root";
            group = "root";
            mode = "0400";
            content =
              let
                lines =
                  [
                    "Host tcp-forward-${name}"
                    "    HostName ${ph.${f.ssh.jumpHostSecret}}"
                  ]
                  ++ (lib.optional (f.ssh.jumpUser != "") "    User ${f.ssh.jumpUser}")
                  ++ [
                    "    LocalForward ${f.listenIp}:${toString f.listenPort} ${ph.${f.ssh.targetHostSecret}}:${toString f.ssh.targetPort}"
                  ]
                  ++ (lib.optional (f.ssh.identityFile != "") "    IdentityFile ${f.ssh.identityFile}")
                  ++ [
                    "    ExitOnForwardFailure yes"
                    # ServerAliveInterval/CountMax 是 ssh 层的被动探活，能处理多数网络抖动。
                    # autossh 的 monitoringPort 是更可靠的主动探活，二者互补。
                    "    ServerAliveInterval 30"
                    "    ServerAliveCountMax 3"
                    "    StrictHostKeyChecking accept-new"
                    ""
                  ];
              in
              lib.concatStringsSep "\n" lines;
          }
        )
        sshForwards;

    # ---- one systemd service per forward ----
    systemd.services =
      let
        common = f: {
          wantedBy = lib.optionals f.autoStart [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [
            "network-online.target"
            "run-secrets.d.mount"
          ];
          requires = [ "run-secrets.d.mount" ];
          serviceConfig = {
            Type = "simple";
            Restart = "always";
            RestartSec = "5s";
            NoNewPrivileges = true;
            PrivateTmp = true;
          };
        };

        directScript = name: f: ''
          set -euo pipefail
          host="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.${f.upstreamHostSecret}.path} | ${pkgs.coreutils}/bin/tr -d '[:space:]')"
          if [ -z "$host" ]; then
            echo "empty upstream host for ${name}" >&2
            exit 1
          fi
          exec ${pkgs.socat}/bin/socat \
            TCP-LISTEN:${toString f.listenPort},bind=${f.listenIp},fork,reuseaddr \
            TCP:"$host":${toString f.upstreamPort}
        '';

        sshScript = name: f: ''
          set -euo pipefail
          exec ${pkgs.autossh}/bin/autossh \
            -M ${toString f.ssh.monitoringPort} \
            -F ${config.sops.templates."tcp-forward-${name}.sshconf".path} \
            -N \
            tcp-forward-${name}
        '';

        # autossh 行为通过环境变量调谐（flag 无法表达）。仅 ssh-tunnel 服务需要。
        sshServiceConfig = f: {
          environment = {
            # 第一次连上后等待多久才认为是“稳定”（秒）。启动期网络据据重连不算失败。
            # 默认 30 过保守；本地转发场景几秒即可。
            AUTOSSH_GATETIME = "5";
            # 退避重连：连续失败时每次等待秒数，避免狂连跨公网跳板机。
            AUTOSSH_RETRY = "3";
            # 关键：autossh 退出时把它自己的日志打到 stderr，便于 systemd journal 排障。
            AUTOSSH_DEBUG = "1";
          };
        };
      in
      lib.mapAttrs'
        (
          name: f:
          lib.nameValuePair "tcp-forward-${name}" (
            lib.recursiveUpdate (common f) (
              {
                description = "TCP forward ${name} (${f.mode})";
                script = if f.mode == "direct" then directScript name f else sshScript name f;
              }
              // (lib.optionalAttrs (f.mode == "ssh-tunnel") (sshServiceConfig f))
            )
          )
        )
        enabledForwards;
  };
}
