{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.xray-client;
  mysecrets = inputs.mysecrets;
  secretPath = config.age.secrets."xray-client-conf.json".path;
  uuidSecretPath = config.age.secrets."relay/xray-uuid".path;
  generatedConfigPath = "/run/xray-client/config.json";
  # 临时文件必须以 .json 结尾：xray 按扩展名判断配置格式，
  # config.json.tmp 会被拒（core: Failed to get format），退出码 23。
  generatedConfigTmpPath = "/run/xray-client/config.next.json";
  upstreamXray = pkgs.callPackage ../../../packages/xray-core-bin { };
  markNumber = 102; # 0x66, intentionally outside mihomo's 0x200/0xf00 mark mask
  ensureRoutingScript = pkgs.writeShellScript "xray-client-ensure-routing" ''
    set -euo pipefail

    while ${pkgs.iproute2}/bin/ip rule del priority ${toString cfg.mihomoBypass.policyRulePriority} fwmark ${toString cfg.mihomoBypass.mark} lookup main 2>/dev/null; do :; done
    ${pkgs.iproute2}/bin/ip rule add priority ${toString cfg.mihomoBypass.policyRulePriority} fwmark ${toString cfg.mihomoBypass.mark} lookup main

    while ${pkgs.iproute2}/bin/ip -6 rule del priority ${toString cfg.mihomoBypass.policyRulePriority} fwmark ${toString cfg.mihomoBypass.mark} lookup main 2>/dev/null; do :; done
    ${pkgs.iproute2}/bin/ip -6 rule add priority ${toString cfg.mihomoBypass.policyRulePriority} fwmark ${toString cfg.mihomoBypass.mark} lookup main
  '';
  cleanupRoutingScript = pkgs.writeShellScript "xray-client-cleanup-routing" ''
    set -euo pipefail

    while ${pkgs.iproute2}/bin/ip rule del priority ${toString cfg.mihomoBypass.policyRulePriority} fwmark ${toString cfg.mihomoBypass.mark} lookup main 2>/dev/null; do :; done
    while ${pkgs.iproute2}/bin/ip -6 rule del priority ${toString cfg.mihomoBypass.policyRulePriority} fwmark ${toString cfg.mihomoBypass.mark} lookup main 2>/dev/null; do :; done
  '';
  prepareConfigScript = pkgs.writeShellScript "xray-client-prepare-config" ''
    set -euo pipefail

    install -d -m 0750 -o xray-client -g xray-client /run/xray-client

    # agenix 在 activation 阶段解密，服务启动时文件可能还没落盘，等一会儿。
    i=0
    while [ ! -s ${uuidSecretPath} ]; do
      i=$((i + 1))
      if [ "$i" -ge 60 ]; then
        echo "${uuidSecretPath} 在 60s 内没有出现" >&2
        exit 1
      fi
      sleep 1
    done

    ${pkgs.jq}/bin/jq --argjson mark ${toString cfg.mihomoBypass.mark} '
      def withSockopt:
        .streamSettings = (.streamSettings // {})
        | .streamSettings.sockopt = ((.streamSettings.sockopt // {}) + { mark: $mark })
        | if .streamSettings.xhttpSettings?.downloadSettings? then
            .streamSettings.xhttpSettings.downloadSettings.sockopt = ((.streamSettings.xhttpSettings.downloadSettings.sockopt // {}) + { mark: $mark })
          else
            .
          end;

      .outbounds = ((.outbounds // []) | map(
        if (.protocol == "freedom" or .protocol == "blackhole") then
          .
        else
          withSockopt
        end
      ))
    ' ${secretPath} > ${generatedConfigTmpPath}

    # jq 对空输入是「退出码 0 + 零字节输出」，不拦的话后面 xray -test 只会给一个
    # 无信息的 status=23。先把「密文没落盘/为空」这种真实故障点报出来。
    if [ ! -s ${generatedConfigTmpPath} ]; then
      echo "生成的 xray 配置为空：${secretPath} 可能是空文件或未被 agenix 解密" >&2
      ls -l ${secretPath} >&2 || true
      exit 1
    fi

    # UUID 只存在于 relay/xray-uuid.age，配置密文里是 __XRAY_UUID__ 占位符。
    # uuid 只含 [0-9a-f-]，sed 替换串里没有需要转义的字符。
    uuid="$(tr -d '\n' < ${uuidSecretPath})"
    sed -i "s|__XRAY_UUID__|$uuid|g" ${generatedConfigTmpPath}

    if grep -q "__XRAY_" ${generatedConfigTmpPath}; then
      echo "xray 配置里仍有未替换的占位符" >&2
      exit 1
    fi

    # 配置错误就在激活阶段炸掉，别让服务起在错误状态上。
    # 注意：xray 把包括报错在内的所有输出都写到 stdout，不能重定向掉，
    # 否则 journal 里只剩一个没有信息量的 status=23。
    if ! ${cfg.package}/bin/xray run -test -c ${generatedConfigTmpPath}; then
      echo "xray 配置自检失败，原因见上面 xray 的输出" >&2
      exit 1
    fi

    chown xray-client:xray-client ${generatedConfigTmpPath}
    chmod 0400 ${generatedConfigTmpPath}
    mv ${generatedConfigTmpPath} ${generatedConfigPath}
  '';
in
{
  options.${namespace}.xray-client = with lib; {
    enable = mkEnableOption "xray client socks proxy";

    package = mkOption {
      type = types.package;
      default = upstreamXray;
      defaultText = lib.literalExpression "pkgs.callPackage ../../../packages/xray-core-bin { }";
      description = "xray package to run.";
    };

    configSecretFile = mkOption {
      type = types.str;
      default = "xray-client-conf.json.age";
      description = "age-encrypted xray client config file under inputs.mysecrets.";
    };

    uuidSecretFile = mkOption {
      type = types.str;
      default = "relay/xray-uuid.age";
      description = ''
        age-encrypted file under inputs.mysecrets holding the upstream VLESS UUID。
        配置密文里对应的位置写 `__XRAY_UUID__`，由 prepare 服务在启动时注入，
        轮换 UUID 只需替换本文件。
      '';
    };

    userId = mkOption {
      type = types.nullOr types.int;
      default = null;
      example = 983;
      description = ''
        Static uid/gid for the xray-client service user; also used by nftables skuid matching.
        Required when mihomoBypass is enabled, because nftables rules are checked at build time
        and cannot resolve dynamically allocated NixOS users in the build sandbox.
      '';
    };

    mihomoBypass = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Mark xray-client outbound packets and route them through the main table,
          so mihomo TUN will not capture xray's own upstream connections.
        '';
      };

      mark = mkOption {
        type = types.int;
        default = markNumber;
        description = "Firewall mark used for xray-client outbound packets.";
      };

      injectXraySockopt = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Generate a runtime xray config from the encrypted one: inject
          streamSettings.sockopt.mark into proxy outbounds, and substitute the
          __XRAY_UUID__ placeholder with the value from uuidSecretFile.

          不能关闭：配置密文里的 UUID 已经是占位符，关掉后 xray 会拿字面量启动。
        '';
      };

      policyRulePriority = mkOption {
        type = types.int;
        default = 50;
        description = "Priority for fwmark policy routing rules used by xray-client.";
      };

    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.mihomoBypass.enable || cfg.userId != null;
        message = "${namespace}.xray-client.userId must be set when mihomoBypass is enabled.";
      }
      {
        # 配置密文里是 __XRAY_UUID__，真值只有 prepare 服务注入；
        # 关掉注入等于让 xray 拿字面量当 uuid 启动。
        assertion = cfg.mihomoBypass.injectXraySockopt;
        message = "${namespace}.xray-client.mihomoBypass.injectXraySockopt 不能关闭：配置密文依赖 prepare 服务注入 UUID。";
      }
    ];

    age.secrets."xray-client-conf.json" = {
      file = "${mysecrets}/${cfg.configSecretFile}";
      owner = "xray-client";
      group = "xray-client";
      mode = "0400";
    };

    # UUID 与配置分离（同 miho 的 relay/*）：配置里只有占位符，
    # 真值在 prepare 服务里注入到 /run/xray-client/config.json。
    age.secrets."relay/xray-uuid" = {
      file = "${mysecrets}/${cfg.uuidSecretFile}";
    };

    users.groups.xray-client = {
      gid = cfg.userId;
    };
    users.users.xray-client = {
      isSystemUser = true;
      uid = cfg.userId;
      group = "xray-client";
      description = "xray client service user";
    };

    environment.systemPackages =
      [ cfg.package ]
      ++ lib.optionals cfg.mihomoBypass.enable [
        pkgs.iproute2
        pkgs.jq
      ];

    systemd.tmpfiles.rules = lib.mkIf cfg.mihomoBypass.injectXraySockopt [
      "d /run/xray-client 0750 xray-client xray-client - -"
    ];

    systemd.services.xray-client = {
      description = "Xray client SOCKS proxy";
      after = [ "network-online.target" "run-agenix.d.mount" "nftables.service" ];
      wants = [ "network-online.target" "nftables.service" ];
      requires = [ "run-agenix.d.mount" ];
      path = lib.optionals cfg.mihomoBypass.enable [
        pkgs.iproute2
        pkgs.jq
        # prepare 脚本里用到的裸命令（tr/sed/grep/install/chmod）
        pkgs.coreutils
        pkgs.gnused
        pkgs.gnugrep
      ];
      wantedBy = [ "multi-user.target" ];
      # agenix 的路径是稳定的 /run/agenix/...，换密文内容时 unit 文本不变，
      # nixos-rebuild 不会重启服务。用内容哈希做触发器：只有这两份密文真的变了
      # 才重启，避免无关 secrets 变更连带重启。
      restartTriggers = [
        (builtins.hashFile "sha256" "${mysecrets}/${cfg.configSecretFile}")
        (builtins.hashFile "sha256" "${mysecrets}/${cfg.uuidSecretFile}")
      ];
      serviceConfig = {
        Type = "simple";
        User = "xray-client";
        Group = "xray-client";
        ExecStartPre = lib.optionals cfg.mihomoBypass.enable [
          "+${ensureRoutingScript}"
        ] ++ lib.optional cfg.mihomoBypass.injectXraySockopt "+${prepareConfigScript}";
        ExecStopPost = lib.optionals cfg.mihomoBypass.enable [
          "+${cleanupRoutingScript}"
        ];
        ExecStart = "${cfg.package}/bin/xray -config ${if cfg.mihomoBypass.injectXraySockopt then generatedConfigPath else secretPath}";
        Restart = "on-failure";
        RestartSec = "3s";
        AmbientCapabilities = lib.optional cfg.mihomoBypass.injectXraySockopt "CAP_NET_ADMIN";
        CapabilityBoundingSet = lib.optional cfg.mihomoBypass.injectXraySockopt "CAP_NET_ADMIN";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = lib.optional cfg.mihomoBypass.injectXraySockopt "/run/xray-client";
        ReadOnlyPaths = [ secretPath ];
      };
    };
  };
}
