{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  system,
  ...
}:
let
  mysecrets = inputs.mysecrets;
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  cfg = config.${namespace}.miho;
  mihomoExtraConfigFile = (pkgs.formats.yaml { }).generate "mihomo-extra.yaml" cfg.extraConfig;
in
{

  options.${namespace}.miho = with lib; {
    enable = mkEnableOption "Enable mihomo";
    extraConfig = mkOption {
      type = types.attrs;
      default = { };
    };
  };

  config = lib.mkIf cfg.enable {

    environment.systemPackages = with pkgs; [ pkgs-unstable.mihomo ];

    age.secrets.miho-conf.file = "${mysecrets}/miho-conf/zen14-test.age";

    services.mihomo = {
      enable = true;
      package = pkgs-unstable.mihomo;
      configFile = "/run/mihomo/config.yaml";
      tunMode = true;
    };

    systemd.services.mihomo-prepare-config = {
      description = "Prepare merged mihomo config";
      before = [ "mihomo.service" ];
      after = [ "run-agenix.d.mount" ];
      requires = [ "run-agenix.d.mount" ];
      path = with pkgs; [
        coreutils
        iproute2
        yq-go
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -euo pipefail

        i=0
        while [ "$i" -lt 60 ]; do
          if [ -s /run/agenix/miho-conf ]; then
            break
          fi
          i=$((i + 1))
          sleep 1
        done

        if [ ! -s /run/agenix/miho-conf ]; then
          echo "/run/agenix/miho-conf is missing or empty after 60s" >&2
          ls -la /run/agenix /run/agenix.d 2>/dev/null || true
          exit 1
        fi

        ip -4 addr show dev lo | grep -q '169.254.53.53/32' || ip addr add 169.254.53.53/32 dev lo

        install -d -m 0700 /run/mihomo
        yq eval-all 'select(fileIndex == 0) *+ select(fileIndex == 1)' \
          /run/agenix/miho-conf \
          ${mihomoExtraConfigFile} > /run/mihomo/config.yaml
        chmod 0600 /run/mihomo/config.yaml
      '';
    };

    systemd.services.mihomo = {
      after = [ "mihomo-prepare-config.service" ];
      requires = [ "mihomo-prepare-config.service" ];
      serviceConfig = {
        AmbientCapabilities = lib.mkForce "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = lib.mkForce "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
      };
    };

  };

}
