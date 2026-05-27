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
  generatedConfigPath = "/run/xray-client/config.json";
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
    ' ${secretPath} > ${generatedConfigPath}.tmp

    chown xray-client:xray-client ${generatedConfigPath}.tmp
    chmod 0400 ${generatedConfigPath}.tmp
    mv ${generatedConfigPath}.tmp ${generatedConfigPath}
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
          Generate a runtime xray config with streamSettings.sockopt.mark injected
          into proxy outbounds. This makes xray set SO_MARK on its own sockets,
          which is more reliable for UDP/QUIC/H3 than nftables skuid marking alone.
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
    ];

    age.secrets."xray-client-conf.json" = {
      file = "${mysecrets}/${cfg.configSecretFile}";
      owner = "xray-client";
      group = "xray-client";
      mode = "0400";
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
      ];
      wantedBy = [ "multi-user.target" ];
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
