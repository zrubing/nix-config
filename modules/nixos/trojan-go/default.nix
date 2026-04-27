{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.trojan-go;
  mysecrets = inputs.mysecrets;
in
{
  options.${namespace}.trojan-go = with lib; {
    enable = mkEnableOption "trojan-go client service";

    package = mkOption {
      type = types.package;
      default = pkgs.${namespace}.trojan-go;
      defaultText = lib.literalExpression "pkgs.${namespace}.trojan-go";
      description = "trojan-go package to run.";
    };

    configSecretFile = mkOption {
      type = types.str;
      default = "trojan-go-client-conf.age";
      description = "age-encrypted trojan-go client config file under inputs.mysecrets.";
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets.trojan-go-client-conf = {
      file = "${mysecrets}/${cfg.configSecretFile}";
      owner = "trojan-go";
      group = "trojan-go";
      mode = "0400";
    };

    users.groups.trojan-go = { };
    users.users.trojan-go = {
      isSystemUser = true;
      group = "trojan-go";
      description = "trojan-go service user";
    };

    environment.systemPackages = [ cfg.package ];

    systemd.services.trojan-go-client = {
      description = "trojan-go client";
      documentation = [ "https://p4gefau1t.github.io/trojan-go/" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "run-agenix.d.mount"
      ];
      requires = [ "run-agenix.d.mount" ];

      serviceConfig = {
        Type = "simple";
        User = "trojan-go";
        Group = "trojan-go";
        ExecStart = "${cfg.package}/bin/trojan-go -config ${config.age.secrets.trojan-go-client-conf.path}";
        Restart = "on-failure";
        RestartSec = "5s";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadOnlyPaths = [ config.age.secrets.trojan-go-client-conf.path ];
      };
    };
  };
}
