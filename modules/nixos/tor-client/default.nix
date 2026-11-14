{ config, inputs, lib, namespace, pkgs, ... }:

let
  lyrebird = pkgs.writeShellScript "tor-lyrebird" ''
    exec ${pkgs.obfs4}/bin/lyrebird "$@"
  '';

  # tor 的出站全部经旁路 socks（net-policy.forcedProxySocksPort）出境，而不是
  # 直连网桥。旁路端口固定走代理组、完全不看 rules，正是这里要的语义：tor 的
  # 目标地址是境外网桥，rules 对它没有意义。
  #
  # 机制：Socks5Proxy 会以 TOR_PT_PROXY 环境变量传给可插拔传输，lyrebird
  # （obfs4proxy 的维护分支）认这个变量，于是**网桥连接本身**也经代理出境——
  # 实测 lyrebird 的出站是 127.0.0.1:7899，没有一条直连网桥 IP 的 socket。
  #
  # 为什么不再直连（2026-11-14 实测）：两条公共 obfs4 网桥里有一条长期握手失败
  # （lyrebird 报 general SOCKS server failure），直连要 ~60s 才 Bootstrap 100%，
  # 目录信息还经常取不全；同一个 tor、同一份网桥经旁路出境，新数据目录 10s 内
  # 100%。
  #
  # 网桥清单（sops 的 tor/zen14/obfs4_bridges）于 2026-11-14 删掉那条死桥后只剩
  # 一条，重启到 Bootstrap 100% 从 ~60s 降到 ~3s，日志里 Failed to find node
  # for hop #1 归零。代价是没有冗余：tor 自己会警告「只有一条网桥，conflux 建议
  # 至少两条」。补一条新 obfs4 桥（BridgeDB / @GetBridgesBot）后加回清单即可。
  #
  # 代价（刻意接受）：tor 从此依赖代理客户端存活。代理重启、组里没有可用节点时
  # tor 一起失效，不再是独立于代理的备用通道。
  #
  # null = 本机没开旁路端口（如未启用代理客户端），退回直连网桥。
  socksProxyPort = config.${namespace}.netPolicy.forcedProxySocksPort;
in
{
  services.tor = {
    enable = true;
    client.enable = true;
    settings =
      {
        # Tor 原生 TLS 在当前网络会被 DPI 重置，必须通过 obfs4 网桥。
        UseBridges = true;
        ClientTransportPlugin = "obfs4 exec ${lyrebird}";
        # %include 是 torrc 原生指令（Tor ≥0.4.6），不等于配置项 Include。
        # NixOS tor 模块会把 settings key 原样输出为 torrc 行。
        "%include" = "/run/tor-client/bridges.conf";
      }
      // lib.optionalAttrs (socksProxyPort != null) {
        # 网桥连接（含 lyrebird 的传输连接）都经这个 socks5 出境。
        Socks5Proxy = "127.0.0.1:${toString socksProxyPort}";
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
