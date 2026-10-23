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

    # resolved 的上游就是本机的 mihomo DNS（listen 127.0.0.1:53，见
    # build-node-extra-config.nix 里那条 listen 覆盖）。这个值属于「当前用哪个
    # 代理」，所以由代理模块声明，不放在 modules/nixos/networking。
    services.resolved.settings.Resolve.DNS = [ "127.0.0.1" ];

    environment.systemPackages = [ pkgs.${namespace}.mihomo ];

    age.secrets.miho-conf.file = "${mysecrets}/miho-conf/zen14-test.age";

    # 中转凭据与配置分离：加密的 miho-conf 里只留占位符，真实值在激活时注入。
    # 轮换密码只需要换 nix-secrets 里的 relay/*.age，不用重写整份 YAML。
    # tuic 的凭据不在这里：mihomo 已经没有 tuic 节点，它连的是本机 tuic-client
    # 开的 socks5（见 modules/nixos/tuic-client），uuid/password 由那边读。
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
      # 注意：agenix 在本仓库是 activation script 安装的（/run/agenix 指向
      # /run/agenix.d/<generation>），并没有 agenix.service 这个单元。
      # 写成 Requires=agenix.service 会让 mihomo 直接起不来：
      #   Failed to restart mihomo.service: Unit agenix.service not found.
      requires = [ "run-agenix.d.mount" ];
      # 重启 mihomo 时连带重跑本单元，这样换完密钥只需 systemctl restart mihomo
      partOf = [ "mihomo.service" ];
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

        # 两个输入都要就绪：主配置 + hysteria2 密码
        for f in miho-conf relay/hysteria-password; do
          i=0
          while [ "$i" -lt 60 ]; do
            [ -s "/run/agenix/$f" ] && break
            i=$((i + 1))
            sleep 1
          done
          if [ ! -s "/run/agenix/$f" ]; then
            echo "/run/agenix/$f is missing or empty after 60s" >&2
            ls -la /run/agenix /run/agenix.d 2>/dev/null || true
            exit 1
          fi
        done

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
        hy2_pw="$(tr -d '\n' < ${config.age.secrets."relay/hysteria-password".path})"
        sed -i \
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
      # 密文 / extraConfig 内容变了要重启。agenix 路径是稳定的 /run/agenix/...，
      # unit 文本不变时 nixos-rebuild 不会动服务；用内容哈希做触发器，避免
      # 换无关 secrets 时被连带重启。
      restartTriggers = [
        (builtins.hashFile "sha256" "${mysecrets}/miho-conf/zen14-test.age")
        (builtins.hashFile "sha256" "${mysecrets}/relay/hysteria-password.age")
        mihomoExtraConfigFile
      ];
      serviceConfig = {
        AmbientCapabilities = lib.mkForce "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = lib.mkForce "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
      };
    };

  };

}
