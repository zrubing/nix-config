# dae 客户端（eBPF 透明代理，代号 dae）。
#
# 与 miho / sib 三选一：三个模块都在，主机配置里只启用一个。同时启用会在
# eval 阶段被断言拦下——它们都要接管全机流量（miho/sib 抢 TUN、nftables 和
# 127.0.0.1:53，dae 抢 tc eBPF 和 DNS 拦截），撞在一起是互相打死。
#
# 和 miho/sib 的结构性差异：dae 不建 TUN，也不监听 127.0.0.1:53，它靠 eBPF
# 在 tc 层把流量改道到 tproxy 端口，DNS 则靠拦截出网的 :53 查询。所以：
#   1. systemd-resolved 的上游必须是外网地址（这里用 223.5.5.5），
#      指向 127.0.0.1 会让 DNS 永远进不了 dae，域名分流直接失效；
#   2. 本机代理客户端（xray-client / tuic-client）的出站必须 must_direct，
#      否则 dae 会把它们连节点的流量再代理一遍，形成自环。
#
# !! 2026-10 实测：dae 与 cilium 在本机不能共存。cilium 用 tcx 挂
# cil_to_netdev/cil_from_netdev，内核对带 tcx 的设备把 clsact 标记为独占，
# dae 的 tc filter 能挂上但永不执行（bpftool 里 tproxy_wan_egress 的
# run_cnt 恒为 0）。修法：cilium 的 bpf.enableTCX=false 退回 legacy tc，
# 或 dae 换用不依赖 WAN egress 的方案。完整证据见 docs/dae-cilium-tcx.md。
#
# 配置来源：nix-secrets 里的加密 .dae（dae-conf/<host>.dae.age），
# 中转 hy2 密码是 __RELAY_HYSTERIA_PASSWORD__ 占位符，激活时从
# relay/hysteria-password 注入，轮换密码不用重加密整份配置。
{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.dae;
  mysecrets = inputs.mysecrets;

  runtimeDir = "/run/dae";
  configPath = "${runtimeDir}/config.dae";
  tmpConfigPath = "${runtimeDir}/config.next.dae";

  secretPath = config.age.secrets."dae-conf".path;
  hy2PasswordPath = config.age.secrets."relay/hysteria-password".path;

  prepareConfigScript = pkgs.writeShellScript "dae-prepare-config" ''
    set -euo pipefail

    install -d -m 0700 ${runtimeDir}

    # agenix 在 activation 阶段解密，服务启动时可能还没落盘。
    for f in ${secretPath} ${hy2PasswordPath}; do
      i=0
      while [ ! -s "$f" ]; do
        i=$((i + 1))
        if [ "$i" -ge 60 ]; then
          echo "$f 在 60s 内没有出现" >&2
          exit 1
        fi
        sleep 1
      done
    done

    # 密码由 token_urlsafe 生成，只含 [A-Za-z0-9_-]，sed 替换串无需转义。
    hy2_pw="$(tr -d '\n' < ${hy2PasswordPath})"
    sed "s|__RELAY_HYSTERIA_PASSWORD__|$hy2_pw|g" ${secretPath} > ${tmpConfigPath}

    if grep -q "__RELAY_" ${tmpConfigPath}; then
      echo "dae 配置里仍有未替换的占位符" >&2
      exit 1
    fi

    # dae 拒绝权限过宽的配置，且会把它当启动失败；先收紧再自检。
    chmod 0600 ${tmpConfigPath}
    if ! ${cfg.package}/bin/dae validate -c ${tmpConfigPath}; then
      echo "dae 配置自检失败，原因见上面 dae 的输出" >&2
      exit 1
    fi

    mv ${tmpConfigPath} ${configPath}
  '';
in
{
  options.${namespace}.dae = with lib; {
    enable = mkEnableOption "dae client (eBPF transparent proxy)";

    package = mkOption {
      type = types.package;
      default = pkgs.dae;
      defaultText = lib.literalExpression "pkgs.dae";
      description = "dae package to run.";
    };

    configSecretFile = mkOption {
      type = types.str;
      default = "dae-conf/zen14.dae.age";
      description = ''
        inputs.mysecrets 下的加密 dae 配置。
        里面的中转密码写 `__RELAY_HYSTERIA_PASSWORD__`，启动时从
        relay/hysteria-password 注入。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # net-policy 的不变量（NTP/123、ET/集群网段不进代理）**尚未接入 dae**：
    # 它的配置是一份密文里的 .dae 文本，没有对应的渲染器。启用 dae 就等于放弃
    # 那些不变量（时钟可能重新走进代理），所以先显式告警，别让切换变得无声无息。
    # 该项工作的前置条件见本文件顶部注释：dae 与 cilium 目前在本机不能共存。
    warnings = [
      ''
        ${namespace}.dae 已启用，但 net-policy 的代理不变量（NTP 直连、ET/集群网段
        不进代理）尚未为 dae 实现渲染器。请确认 ${namespace}.netPolicy 的条目在
        ${config.age.secrets."dae-conf".path} 里有等价声明，否则切回 miho/sib 前
        先核对 docs/net-invariants.md。
      ''
    ];

    assertions = [
      {
        assertion = !config.${namespace}.miho.enable;
        message = ''
          ${namespace}.dae 与 ${namespace}.miho 不能同时启用：两者都要接管全机流量。
          切换时在主机配置里一开一关。
        '';
      }
      {
        assertion = !config.${namespace}.sib.enable;
        message = ''
          ${namespace}.dae 与 ${namespace}.sib 不能同时启用：两者都要接管全机流量。
          切换时在主机配置里一开一关。
        '';
      }
    ];

    # dae 不提供本地 DNS 服务，只能靠 resolved 把查询发出网卡后被 eBPF 截获。
    # 这个值属于「当前用哪个代理」，所以由代理模块自己声明，不放在 networking 里。
    services.resolved.settings.Resolve.DNS = [ "223.5.5.5" ];

    age.secrets."dae-conf" = {
      file = "${mysecrets}/${cfg.configSecretFile}";
    };

    age.secrets."relay/hysteria-password".file = "${mysecrets}/relay/hysteria-password.age";

    services.dae = {
      enable = true;
      package = cfg.package;
      configFile = configPath;
      # tproxy 端口只由本机 eBPF 使用，不需要对局域网开口。
      openFirewall.enable = false;
    };

    systemd.services.dae-prepare-config = {
      description = "Prepare dae config";
      before = [ "dae.service" ];
      after = [ "run-agenix.d.mount" ];
      # agenix 在本仓库是 activation script 安装的（/run/agenix 指向
      # /run/agenix.d/<generation>），没有 agenix.service 单元。
      requires = [ "run-agenix.d.mount" ];
      # 重启 dae 时连带重跑本单元，换完密码只需 systemctl restart dae
      partOf = [ "dae.service" ];
      environment.DAE_LOCATION_ASSET = config.services.dae.assetsPath;
      path = with pkgs; [
        coreutils
        gnused
        gnugrep
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = prepareConfigScript;
      };
    };

    systemd.services.dae = {
      after = [
        "dae-prepare-config.service"
        # 软依赖：1086/1087/12190 这三条 socks 节点来自这两个客户端。
        # dae 起得比它们早只是少了几个节点，不该被拖死。
        "xray-client.service"
        "tuic-client.service"
      ];
      wants = [
        "xray-client.service"
        "tuic-client.service"
      ];
      requires = [ "dae-prepare-config.service" ];
      # 与另外两个代理互斥：即便有人手动 start，也不会同时抢流量
      conflicts = [
        "mihomo.service"
        "sib.service"
      ];
      # 上游 unit 是 Restart=on-abnormal，配置错误（退出码 1）不会重试；
      # 这里改成 on-failure，让自检失败以外的崩溃能自愈。
      serviceConfig.Restart = "on-failure";
      serviceConfig.RestartSec = "3s";
      # 密文内容变了就重启（agenix 路径稳定，unit 文本不变，不写这条不会动）。
      restartTriggers = [
        (builtins.hashFile "sha256" "${mysecrets}/${cfg.configSecretFile}")
        (builtins.hashFile "sha256" "${mysecrets}/relay/hysteria-password.age")
      ];
    };
  };
}
