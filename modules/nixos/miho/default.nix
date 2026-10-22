{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  mysecrets = inputs.mysecrets;
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

    environment.systemPackages = [ pkgs.${namespace}.mihomo ];

    age.secrets.miho-conf.file = "${mysecrets}/miho-conf/zen14-test.age";

    # 中转凭据与配置分离：加密的 miho-conf 里只留占位符，真实值在激活时注入。
    # 轮换密码只需要换 nix-secrets 里的 relay/*.age，不用重写整份 YAML。
    age.secrets."relay/tuic-password".file = "${mysecrets}/relay/tuic-password.age";
    age.secrets."relay/hysteria-password".file = "${mysecrets}/relay/hysteria-password.age";

    services.mihomo = {
      enable = true;
      package = pkgs.${namespace}.mihomo;
      configFile = "/run/mihomo/config.yaml";
      tunMode = true;
    };

    systemd.services.mihomo-prepare-config = {
      description = "Prepare merged mihomo config";
      before = [ "mihomo.service" ];
      after = [ "run-agenix.d.mount" ];
      # 两个 relay 密码要在占位符替换前就绪
      requires = [ "run-agenix.d.mount" "agenix.service" ];
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
          ${mihomoExtraConfigFile} > /run/mihomo/config.yaml.tmp
        yq eval-all --inplace 'select(fileIndex == 0) * select(fileIndex == 1)' \
          /run/mihomo/config.yaml.tmp \
          ${mihomoExtraConfigFile}
        mv /run/mihomo/config.yaml.tmp /run/mihomo/config.yaml

        # 占位符替换。密码由 token_urlsafe 生成，只含 [A-Za-z0-9_-]，
        # sed 的替换串里不会出现需要转义的字符。
        tuic_pw="$(tr -d '\n' < ${config.age.secrets."relay/tuic-password".path})"
        hy2_pw="$(tr -d '\n' < ${config.age.secrets."relay/hysteria-password".path})"
        sed -i \
          -e "s|__RELAY_TUIC_PASSWORD__|$tuic_pw|g" \
          -e "s|__RELAY_HYSTERIA_PASSWORD__|$hy2_pw|g" \
          /run/mihomo/config.yaml

        if grep -q "__RELAY_" /run/mihomo/config.yaml; then
          echo "mihomo 配置里仍有未替换的占位符" >&2
          exit 1
        fi

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
