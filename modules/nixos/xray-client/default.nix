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
in
{
  options.${namespace}.xray-client = with lib; {
    enable = mkEnableOption "xray client socks proxy";

    package = mkOption {
      type = types.package;
      default = pkgs.xray;
      defaultText = lib.literalExpression "pkgs.xray";
      description = "xray package to run.";
    };

    configSecretFile = mkOption {
      type = types.str;
      default = "xray-client-conf.json.age";
      description = "age-encrypted xray client config file under inputs.mysecrets.";
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets."xray-client-conf.json" = {
      file = "${mysecrets}/${cfg.configSecretFile}";
      owner = "xray-client";
      group = "xray-client";
      mode = "0400";
    };

    users.groups.xray-client = { };
    users.users.xray-client = {
      isSystemUser = true;
      group = "xray-client";
      description = "xray client service user";
    };

    environment.systemPackages = [ cfg.package ];

    systemd.services.xray-client = {
      description = "Xray client SOCKS proxy";
      after = [ "network-online.target" "run-agenix.d.mount" ];
      wants = [ "network-online.target" ];
      requires = [ "run-agenix.d.mount" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = "xray-client";
        Group = "xray-client";
        ExecStart = "${cfg.package}/bin/xray -config ${secretPath}";
        Restart = "on-failure";
        RestartSec = "3s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadOnlyPaths = [ secretPath ];
      };
    };
  };
}
