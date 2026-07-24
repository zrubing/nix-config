{ config, inputs, lib, pkgs, ... }:

let
  lyrebird = pkgs.writeShellScript "tor-lyrebird" ''
    exec ${pkgs.obfs4}/bin/lyrebird "$@"
  '';
in
{
  services.tor = {
    enable = true;
    client.enable = true;
    settings = {
      # Tor 原生 TLS 在当前网络会被 DPI 重置，必须通过 obfs4 网桥。
      UseBridges = true;
      ClientTransportPlugin = "obfs4 exec ${lyrebird}";
      # %include 是 torrc 原生指令（Tor ≥0.4.6），不等于配置项 Include。
      # NixOS tor 模块会把 settings key 原样输出为 torrc 行。
      "%include" = "/run/tor-client/bridges.conf";
    };
  };

  sops.secrets."tor/zen14/obfs4_bridges" = {
    sopsFile = "${inputs.mysecrets}/secrets/env.yaml";
  };

  # sops-nix 密文在 nixos-rebuild switch activation 阶段同步解密到
  # /run/secrets/，不存在独立的 systemd 服务。tor-bridges-config 内置
  # wait loop 兜底。oneshot + RemainAfterExit 避免 tor 重启时连带触发
  # start-limit。
  systemd.services.tor-bridges-config = {
    description = "Generate Tor bridge config from SOPS secret";
    path = with pkgs; [ coreutils gawk ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      secret=${config.sops.secrets."tor/zen14/obfs4_bridges".path}
      i=0
      while [ "$i" -lt 60 ]; do
        if [ -s "$secret" ]; then
          break
        fi
        i=$((i + 1))
        sleep 1
      done
      if [ ! -s "$secret" ]; then
        echo "$secret is missing or empty after 60s" >&2
        exit 1
      fi
      install -d -m 0755 /run/tor-client
      awk '{print "Bridge " $0}' "$secret" > /run/tor-client/bridges.conf
      chmod 0644 /run/tor-client/bridges.conf
    '';
  };

  systemd.services.tor = {
    after = [ "tor-bridges-config.service" ];
    requires = [ "tor-bridges-config.service" ];
    serviceConfig.BindReadOnlyPaths = lib.mkAfter [ "/run/tor-client:/run/tor-client" ];
  };

  environment.systemPackages = [ pkgs.torsocks ];
}
