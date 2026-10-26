{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.tuic-client;
  mysecrets = inputs.mysecrets;

  # 每个实例 = 一个上游节点 + 一个本地 SOCKS5 端口。
  # uuid / password 全机共用（同一套服务端凭据），只有 server 地址和端口不同，
  # 所以 server 一份密文，uuid/password 只声明一次。
  instanceModule = {
    options = {
      serverSecret = lib.mkOption {
        type = lib.types.str;
        description = ''
          mysecrets 下存放 "host:port" 单行的 age 密文名（不含 .age）。
          SNI 由客户端从 host 推导。
        '';
      };

      listen = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:12190";
        description = "本地 SOCKS5 监听地址（TCP + UDP ASSOCIATE 同一端口）。";
      };
    };
  };

  # 配置在启动时渲染：age 密文里的 server/uuid/password 只以文件形式出现，
  # 明文配置只落在 tmpfs（/run）上，权限 0400、属主是服务用户。
  renderConfig =
    name: inst:
    pkgs.writeShellScript "tuic-client-${name}-render-config" ''
      set -euo pipefail

      install -d -m 0750 -o ${cfg.user} -g ${cfg.group} /run/tuic-client-${name}

      umask 077
      {
        printf 'server = "%s"\n' "$(tr -d '\n' < ${config.age.secrets.${inst.serverSecret}.path})"
        printf 'uuid = "%s"\n' "$(tr -d '\n' < ${config.age.secrets."relay/tuic-uuid".path})"
        printf 'password = "%s"\n' "$(tr -d '\n' < ${config.age.secrets."relay/tuic-password".path})"
        printf 'log_level = "%s"\n' ${lib.escapeShellArg cfg.logLevel}
        printf 'udp_relay_mode = "native"\n'
        printf 'reconnect = true\n'
        ${lib.optionalString cfg.skipCertVerify ''
          printf '\n[tls]\n'
          printf 'skip_cert_verify = true\n'
        ''}
        printf '\n[local]\n'
        printf 'server = "%s"\n' ${lib.escapeShellArg inst.listen}
      } > /run/tuic-client-${name}/config-with-secret.toml.tmp

      chown ${cfg.user}:${cfg.group} /run/tuic-client-${name}/config-with-secret.toml.tmp
      chmod 0400 /run/tuic-client-${name}/config-with-secret.toml.tmp
      mv /run/tuic-client-${name}/config-with-secret.toml.tmp /run/tuic-client-${name}/config-with-secret.toml
    '';
in
{
  options.${namespace}.tuic-client = with lib; {
    enable = mkEnableOption "TUIC v2 client exposing local SOCKS5 inbounds";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../../../packages/tuic-client-bin { };
      defaultText = lib.literalExpression "pkgs.callPackage ../../../packages/tuic-client-bin { }";
      description = "tuic-client package to run.";
    };

    logLevel = mkOption {
      type = types.str;
      # info 会把每个 UDP 包都写一行：实测 2 分钟 2670 行，一天上百 MB。
      # 排障时临时设成 info，平时 warn。
      default = "warn";
      description = "tuic-client 日志级别。";
    };

    skipCertVerify = mkOption {
      type = types.bool;
      default = false;
      description = "跳过证书校验。仅用于排查证书链问题，正常情况不要打开。";
    };

    user = mkOption {
      type = types.str;
      default = "tuic-client";
      description = "运行服务的系统用户。";
    };

    group = mkOption {
      type = types.str;
      default = "tuic-client";
      description = "运行服务的系统组。";
    };

    instances = mkOption {
      type = types.attrsOf (types.submodule instanceModule);
      default = { };
      description = "TUIC 上游实例，键名进 unit 名（tuic-client-<name>）。";
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets =
      {
        "relay/tuic-uuid".file = "${mysecrets}/relay/tuic-uuid.age";
        "relay/tuic-password".file = "${mysecrets}/relay/tuic-password.age";
      }
      # 服务端地址不写进公开仓库的 nix 文件，和 uuid/password 一样走密文。
      // lib.mapAttrs' (
        _: inst: lib.nameValuePair inst.serverSecret { file = "${mysecrets}/${inst.serverSecret}.age"; }
      ) cfg.instances;

    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
    };

    systemd.services = lib.mapAttrs' (
      name: inst:
      lib.nameValuePair "tuic-client-${name}" {
        description = "TUIC v2 client (SOCKS5 ${inst.listen})";
        after = [
          "network-online.target"
          "run-agenix.d.mount"
        ];
        wants = [ "network-online.target" ];
        # agenix 在本仓库是 activation script 安装的（/run/agenix 指向
        # /run/agenix.d/<generation>），没有 agenix.service 这个单元。
        requires = [ "run-agenix.d.mount" ];
        wantedBy = [ "multi-user.target" ];
        # 密文内容变了就重启（agenix 路径稳定，unit 文本不变，不写这条不会动）。
        restartTriggers = [
          (builtins.hashFile "sha256" "${mysecrets}/${inst.serverSecret}.age")
          (builtins.hashFile "sha256" "${mysecrets}/relay/tuic-uuid.age")
          (builtins.hashFile "sha256" "${mysecrets}/relay/tuic-password.age")
        ];

        serviceConfig = {
          Type = "simple";
          User = cfg.user;
          Group = cfg.group;
          # `+` 前缀 = 以 root 跑（ExecStartPre 默认继承 User=），
          # 只有它需要读 /run/agenix 下 root:0400 的密文。
          ExecStartPre = "+${renderConfig name inst}";
          ExecStart = "${cfg.package}/bin/tuic-client --config /run/tuic-client-${name}/config-with-secret.toml";
          Restart = "always";
          RestartSec = 5;

          RuntimeDirectory = "tuic-client-${name}";
          RuntimeDirectoryMode = "0750";

          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          LockPersonality = true;
        };
      }
    ) cfg.instances
    # mihomo 把 tuic 节点当成 127.0.0.1 上的 socks5 上游，先起客户端再起 mihomo。
    // lib.optionalAttrs config.${namespace}.miho.enable {
      mihomo = {
        after = lib.mapAttrsToList (name: _: "tuic-client-${name}.service") cfg.instances;
        wants = lib.mapAttrsToList (name: _: "tuic-client-${name}.service") cfg.instances;
      };
    };
  };
}
