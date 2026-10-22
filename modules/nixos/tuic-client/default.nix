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

  uuidSecret = config.age.secrets."relay/tuic-uuid".path;
  passwordSecret = config.age.secrets."relay/tuic-password".path;

  runtimeDir = "/run/tuic-client";
  configPath = "${runtimeDir}/config.toml";

  # 配置在启动时渲染：age 密文里的 uuid/password 只以文件形式出现，
  # 明文配置只落在 tmpfs（/run）上，权限 0400、属主是服务用户。
  renderConfig = pkgs.writeShellScript "tuic-client-render-config" ''
    set -euo pipefail

    install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${runtimeDir}

    umask 077
    {
      printf 'server = "%s"\n' ${lib.escapeShellArg cfg.server}
      printf 'uuid = "%s"\n' "$(tr -d '\n' < ${uuidSecret})"
      printf 'password = "%s"\n' "$(tr -d '\n' < ${passwordSecret})"
      printf 'log_level = "%s"\n' ${lib.escapeShellArg cfg.logLevel}
      printf 'udp_relay_mode = "native"\n'
      printf 'reconnect = true\n'
      ${lib.optionalString (cfg.sni != null || cfg.skipCertVerify) ''
        printf '\n[tls]\n'
      ''}
      ${lib.optionalString (cfg.sni != null) ''
        printf 'sni = "%s"\n' ${lib.escapeShellArg cfg.sni}
      ''}
      ${lib.optionalString cfg.skipCertVerify ''
        printf 'skip_cert_verify = true\n'
      ''}
      printf '\n[local]\n'
      printf 'server = "%s"\n' ${lib.escapeShellArg cfg.listen}
    } > ${configPath}.tmp

    chown ${cfg.user}:${cfg.group} ${configPath}.tmp
    chmod 0400 ${configPath}.tmp
    mv ${configPath}.tmp ${configPath}
  '';
in
{
  options.${namespace}.tuic-client = with lib; {
    enable = mkEnableOption "TUIC v2 client exposing a local SOCKS5 inbound";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../../../packages/tuic-client-bin { };
      defaultText = lib.literalExpression "pkgs.callPackage ../../../packages/tuic-client-bin { }";
      description = "tuic-client package to run.";
    };

    server = mkOption {
      type = types.str;
      example = "relay.invalid:PORT";
      description = ''
        TUIC 服务端地址，`host:port` 形式。必须是字符串而不是数组：
        上游 `deserialize_server` 只接受 `"host:port"`。
      '';
    };

    sni = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "TLS SNI。null 表示用 server 里的主机名。";
    };

    listen = mkOption {
      type = types.str;
      default = "127.0.0.1:12190";
      description = "本地 SOCKS5 监听地址（TCP + UDP ASSOCIATE 同一端口）。";
    };

    logLevel = mkOption {
      type = types.str;
      default = "info";
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
  };

  config = lib.mkIf cfg.enable {
    age.secrets."relay/tuic-uuid".file = "${mysecrets}/relay/tuic-uuid.age";
    age.secrets."relay/tuic-password".file = "${mysecrets}/relay/tuic-password.age";

    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
    };

    systemd.services.tuic-client = {
      description = "TUIC v2 client (SOCKS5 ${cfg.listen} -> ${cfg.server})";
      after = [
        "network-online.target"
        "run-agenix.d.mount"
      ];
      wants = [ "network-online.target" ];
      # agenix 在本仓库是 activation script 安装的（/run/agenix 指向
      # /run/agenix.d/<generation>），没有 agenix.service 这个单元。
      requires = [ "run-agenix.d.mount" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        # `+` 前缀 = 以 root 跑（ExecStartPre 默认继承 User=），
        # 只有它需要读 /run/agenix 下 root:0400 的密文。
        ExecStartPre = "+${renderConfig}";
        ExecStart = "${cfg.package}/bin/tuic-client --config ${configPath}";
        Restart = "always";
        RestartSec = 5;

        RuntimeDirectory = "tuic-client";
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
    };

    # mihomo 把 tuic 节点当成 127.0.0.1 上的 socks5 上游，先起客户端再起 mihomo。
    systemd.services.mihomo = lib.mkIf config.${namespace}.miho.enable {
      after = [ "tuic-client.service" ];
      wants = [ "tuic-client.service" ];
    };
  };
}
