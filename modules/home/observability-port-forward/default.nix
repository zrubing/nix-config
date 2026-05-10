{ config, lib, pkgs, ... }:
let
  cfg = config.internal.observabilityPortForward;
in
{
  options.internal.observabilityPortForward = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable local user-level port-forwards for hinihao observability services.";
    };

    kubeconfig = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.kube/config-k0s.yml";
      description = "Kubeconfig used by kubectl port-forward.";
    };

    lokiAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.10";
      description = "Local loopback address for Loki.";
    };

    tempoAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.11";
      description = "Local loopback address for Tempo.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.sessionVariables = {
      LOKI_ADDR = "http://loki.local:3100";
      TEMPO_ADDR = "http://tempo.local:3200";
      NO_PROXY = "127.0.0.1,127.0.0.0/8,localhost,loki.local,tempo.local";
      no_proxy = "127.0.0.1,127.0.0.0/8,localhost,loki.local,tempo.local";
    };

    systemd.user.services.observability-loki-port-forward = {
      Unit = {
        Description = "Port-forward hinihao Loki to loki.local:3100";
        After = [ "network-online.target" ];
      };

      Service = {
        ExecStart = "${pkgs.kubectl}/bin/kubectl --kubeconfig ${cfg.kubeconfig} -n observability port-forward --address ${cfg.lokiAddress} svc/loki 3100:3100";
        Restart = "always";
        RestartSec = 5;
      };

      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.observability-tempo-port-forward = {
      Unit = {
        Description = "Port-forward hinihao Tempo to tempo.local:3200";
        After = [ "network-online.target" ];
      };

      Service = {
        ExecStart = "${pkgs.kubectl}/bin/kubectl --kubeconfig ${cfg.kubeconfig} -n observability port-forward --address ${cfg.tempoAddress} svc/tempo 3200:3200";
        Restart = "always";
        RestartSec = 5;
      };

      Install.WantedBy = [ "default.target" ];
    };
  };
}
