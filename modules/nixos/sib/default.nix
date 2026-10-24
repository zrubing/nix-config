# sing-box 客户端（代号 sib）。
#
# 与 miho 模块并存：两个模块都在，主机配置里二选一启用。
# 同时启用会在 eval 阶段被断言拦下（两者都要抢 TUN、127.0.0.1:53 和 nftables 规则）。
#
# 配置来源：nix-secrets 里的加密 JSON（sib-conf/<host>.json.age），
# 里面 hy2 密码是 __RELAY_HYSTERIA_PASSWORD__ 占位符；真值在激活时从
# relay/hysteria-password 注入，轮换密码不用重加密整份配置。
#
# 为什么不直接用 nixpkgs 的 services.sing-box：那个模块以普通用户运行，
# 不配 TUN 所需的能力，也不支持「密文配置 + 占位符注入」这条路径。
{
  config,
  inputs,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.sib;
  mysecrets = inputs.mysecrets;

  # 主 nixpkgs（nixos-26.05）里的 sing-box 落后一个大版本（1.13.x），
  # 而配置已按 1.14 写（无 independent_cache 等废弃项），所以从 unstable 取。
  # 等主 nixpkgs 跟上就把这里换回 pkgs.sing-box。
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
  };

  # nixpkgs（unstable 与 master 都是）还停在 1.14.3；1.14.4 是 2026-10-24 的纯修复版。
  # 就地覆盖版本，等 nixpkgs 跟进后删掉本段、package 回退到 pkgs-unstable.sing-box。
  # 上游 go.mod 只换了依赖版本，cronet-go 仍是 v0.0.0-20260912104727，
  # 所以 nixpkgs 的 cronet-go 与其补丁（包内 postConfigure 引用的 cronet-go.patch）可原样复用。
  sing-box = pkgs-unstable.sing-box.overrideAttrs (old: {
    version = "1.14.4";
    src = pkgs-unstable.fetchFromGitHub {
      owner = "SagerNet";
      repo = "sing-box";
      tag = "v1.14.4";
      hash = "sha256-1tP0gXUTLGVR32c11nypsZSx2FtBOmKMTJkt+7j/fJU=";
    };
    vendorHash = "sha256-xZWWzvyTrbaxqHG1UdKOVLOd5dPf9z6JfPJf3WeTm5Y=";
  });

  runtimeDir = "/run/sib";
  configPath = "${runtimeDir}/config.json";
  # 临时文件必须以 .json 结尾：xray 那次踩过后缀坑，这里统一带上。
  tmpConfigPath = "${runtimeDir}/config.next.json";

  secretPath = config.age.secrets."sib-conf".path;
  hy2PasswordPath = config.age.secrets."relay/hysteria-password".path;

  prepareConfigScript = pkgs.writeShellScript "sib-prepare-config" ''
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
      echo "sib 配置里仍有未替换的占位符" >&2
      exit 1
    fi

    # 配置错误在启动前炸掉，并让 sing-box 自己把原因打到 journal。
    if ! ${cfg.package}/bin/sing-box check -c ${tmpConfigPath}; then
      echo "sib 配置自检失败，原因见上面 sing-box 的输出" >&2
      exit 1
    fi

    chmod 0600 ${tmpConfigPath}
    mv ${tmpConfigPath} ${configPath}
  '';
in
{
  options.${namespace}.sib = with lib; {
    enable = mkEnableOption "sing-box client (sib)";

    package = mkOption {
      type = types.package;
      default = sing-box;
      defaultText = lib.literalExpression "pkgs-unstable.sing-box（版本覆盖到 1.14.4）";
      description = "sing-box package to run.";
    };

    configSecretFile = mkOption {
      type = types.str;
      default = "sib-conf/zen14.json.age";
      description = ''
        inputs.mysecrets 下的加密 sing-box 配置。
        里面的中转密码写 `__RELAY_HYSTERIA_PASSWORD__`，启动时从
        relay/hysteria-password 注入。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.${namespace}.miho.enable;
        message = ''
          ${namespace}.sib 与 ${namespace}.miho 不能同时启用：两者都要接管 TUN、
          127.0.0.1:53 和 nftables。切换时在主机配置里一开一关。
        '';
      }
    ];

    environment.systemPackages = [ cfg.package ];

    # resolved 的上游就是 sib 自己（配置里的 dns inbound 监听 127.0.0.1:53）。
    # 这个值属于「当前用哪个代理」，所以由代理模块声明，不放在 modules/nixos/networking。
    services.resolved.settings.Resolve.DNS = [ "127.0.0.1" ];

    age.secrets."sib-conf" = {
      file = "${mysecrets}/${cfg.configSecretFile}";
    };

    # miho 关掉后这个 secret 没有别的声明方，sib 自己声明；
    # 两个模块同时声明同一份文件时只是合并，不冲突。
    age.secrets."relay/hysteria-password".file = "${mysecrets}/relay/hysteria-password.age";

    systemd.services.sib-prepare-config = {
      description = "Prepare sib (sing-box) config";
      before = [ "sib.service" ];
      after = [ "run-agenix.d.mount" ];
      # 注意：agenix 在本仓库是 activation script 安装的（/run/agenix 指向
      # /run/agenix.d/<generation>），没有 agenix.service 单元。
      requires = [ "run-agenix.d.mount" ];
      # 重启 sib 时连带重跑本单元，换完密码只需 systemctl restart sib
      partOf = [ "sib.service" ];
      path = with pkgs; [
        coreutils
        gnused
        gnugrep
      ];
      serviceConfig = {
        Type = "oneshot";
        # 用 ExecStart 指向脚本：systemd 的 script= 只接受字符串，不接受 derivation
        ExecStart = prepareConfigScript;
      };
    };

    systemd.services.sib = {
      description = "sing-box (sib) client";
      after = [
        "network-online.target"
        "sib-prepare-config.service"
        # 软依赖：1086/1087 那两个 socks 节点来自 xray-client，先起它只是减少
        # 「启动瞬间节点不可用」的窗口。用 wants 而不是 requires —— xray 挂了
        # 不该连累整个代理起不来，那两条节点交给 url-test 跳过即可。
        "xray-client.service"
      ];
      wants = [
        "network-online.target"
        "xray-client.service"
      ];
      requires = [ "sib-prepare-config.service" ];
      wantedBy = [ "multi-user.target" ];
      # 与 mihomo 互斥：即便有人手动 start，也不会两个 TUN 同时存在
      conflicts = [ "mihomo.service" ];
      # 密文内容变了就重启（agenix 路径稳定，unit 文本不变，不写这条不会动）。
      # 用内容哈希而不是 store 路径：换无关 secrets 不连带重启。
      restartTriggers = [
        (builtins.hashFile "sha256" "${mysecrets}/${cfg.configSecretFile}")
        (builtins.hashFile "sha256" "${mysecrets}/relay/hysteria-password.age")
      ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/sing-box run -c ${configPath}";
        Restart = "on-failure";
        RestartSec = "3s";
        # cache.db 落在这里（配置里 experimental.cache_file.path 指向同一处）
        StateDirectory = "sib";
        StateDirectoryMode = "0700";
        # 需要的能力（少一个就会以难懂的方式坏掉）：
        #   CAP_NET_ADMIN      TUN 建卡、auto_redirect 的 nftables、ip rule
        #   CAP_NET_BIND_SERVICE 绑定 127.0.0.1:53
        #   CAP_NET_RAW        SO_BINDTODEVICE（auto_detect_interface 给每个出站
        #                      socket 绑网卡）。缺它时所有 UDP 出站报
        #                      "listen udp4 :0: operation not permitted"，
        #                      表现为 hy2/QUIC 全 504 而 TCP 节点正常。
        AmbientCapabilities = [
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_RAW"
        ];
        CapabilityBoundingSet = [
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_RAW"
        ];
      };
    };
  };
}
