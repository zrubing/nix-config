# 客户端 IPv6 可用性探测（sib / miho 共用）。
#
# ── 为什么需要 ──────────────────────────────────────────────────────
#
# v6 腿（tag 以 -v6 结尾）在只有 v4 的网络里是一条永远失败的候选。selector
# 一旦停在它上面，表现为「页面一直转圈、日志全是 i/o timeout」；urltest 也会
# 每轮都为它白跑一次健康检查。而 v6 有没有取决于**当前网络**（笔记本换 Wi-Fi、
# 手机热点），构建期无法决定。
#
# ── 本模块做两件事 ──────────────────────────────────────────────────
#
#   1. 产出探测脚本（proxyV6.checkScript）：有可用 v6 → stdout 打 1，没有 → 0。
#      客户端在 prepare 阶段调用它，决定是否把 -v6 节点从配置里剔掉。
#   2. 定时重测；结果翻转（连续两次）时重启当前客户端，让配置重建。
#
# 探测目标由客户端写入 /run/proxy-v6/targets（节点清单里的 v6 字面量），
# 所以本模块不需要知道任何节点/地址信息。
#
# ── 判据是「能不能真的用」，不是「有没有地址」 ──────────────────────
#
#   1. 有非 ULA 的全局 v6 地址 + 默认路由。ULA（fc00::/7）必须排除：它会被
#      net-policy 的 ip_is_private 判成内网直连，也出不了公网。
#   2. 能 ping 通任一节点的 v6 服务器 —— v6 腿就是连这些地址，最贴近用途。
#   3. 都失败再退到公共 v6 目标的 TCP 443（有的网络禁 ICMPv6）。
#
# 只做「地址存在」判断是不够的：地址在、路由黑洞时，v6 腿照样全失败。
{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.proxyV6;

  stateDir = "/run/proxy-v6";
  targetsPath = "${stateDir}/targets";
  availablePath = "${stateDir}/available";

  checkScript = pkgs.writeShellScript "proxy-v6-check" ''
    set -u
    export PATH=${
      lib.makeBinPath [
        pkgs.bash
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnugrep
        pkgs.iproute2
        pkgs.iputils
      ]
    }:$PATH

    have=0
    while read -r a; do
      case "$a" in
        fc* | fd*) continue ;;
      esac
      have=1
      break
    done < <(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' | cut -d/ -f1)
    if [ "$have" != 1 ]; then
      echo 0
      exit 0
    fi
    if ! ip -6 route show default 2>/dev/null | grep -q .; then
      echo 0
      exit 0
    fi

    if [ -s ${targetsPath} ]; then
      while read -r t; do
        [ -n "$t" ] || continue
        if ping -6 -c 1 -W 2 "$t" >/dev/null 2>&1; then
          echo 1
          exit 0
        fi
      done < ${targetsPath}
    fi

    for t in 2606:4700:4700::1111 2620:fe::fe; do
      if timeout 3 bash -c "exec 3<>/dev/tcp/$t/443" 2>/dev/null; then
        echo 1
        exit 0
      fi
    done
    echo 0
  '';

  # 只在结果翻转时重启客户端，且要连续两次不一致：v6 链路抖一下（丢一个
  # ICMP 包）就重启代理会平白掐断所有连接。
  watchScript = pkgs.writeShellScript "proxy-v6-watch" ''
    set -u
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.systemd
      ]
    }:$PATH

    [ -r ${availablePath} ] || exit 0

    cur="$(${checkScript})"
    prev="$(cat ${availablePath} 2>/dev/null || true)"
    if [ "$cur" = "$prev" ]; then
      echo 0 > ${stateDir}/mismatch
      exit 0
    fi

    n=$(( $(cat ${stateDir}/mismatch 2>/dev/null || echo 0) + 1 ))
    echo "$n" > ${stateDir}/mismatch
    if [ "$n" -ge 2 ]; then
      echo "proxy-v6: v6 可用性 $prev -> $cur，重启 ${cfg.clientService} 重建配置" >&2
      systemctl restart ${cfg.clientService} || true
      echo 0 > ${stateDir}/mismatch
    fi
  '';
in
{
  options.${namespace}.proxyV6 = with lib; {
    enable = mkOption {
      type = types.bool;
      # 默认跟随「当前启用的是哪个客户端」，不需要每台机器再写一遍。
      default = config.${namespace}.sib.enable || config.${namespace}.miho.enable;
      defaultText = literalExpression "<namespace>.sib.enable || <namespace>.miho.enable";
      description = ''
        启动/网络变化时探测本机有无可用 v6；没有则让客户端把 tag 以 "-v6"
        结尾的节点从出站与分组里剔掉。

        关掉后 v6 腿无条件保留：本机没有 v6 时它们只是连不上，会在候选里
        留下永远失败的成员。
      '';
    };

    clientService = mkOption {
      type = types.str;
      default = if config.${namespace}.miho.enable then "mihomo.service" else "sib.service";
      defaultText = literalExpression ''if <namespace>.miho.enable then "mihomo.service" else "sib.service"'';
      description = "探测结果翻转时要重启的客户端 unit。";
    };

    checkScript = mkOption {
      type = types.path;
      readOnly = true;
      default = checkScript;
      description = "探测脚本：stdout 打 1（有可用 v6）或 0（没有）。";
    };

    stateDir = mkOption {
      type = types.str;
      readOnly = true;
      default = stateDir;
      description = "运行时状态目录（targets / available / mismatch）。";
    };

    targetsPath = mkOption {
      type = types.str;
      readOnly = true;
      default = targetsPath;
      description = "探测目标文件，每行一个 v6 地址；由客户端 prepare 写入。";
    };

    availablePath = mkOption {
      type = types.str;
      readOnly = true;
      default = availablePath;
      description = "上一次探测结果（1/0），由客户端 prepare 写入。";
    };
  };

  config = lib.mkIf cfg.enable {
    # 状态目录的属主是 root；两个客户端的 prepare 都以 root 跑。
    systemd.tmpfiles.rules = [ "d ${stateDir} 0700 root root -" ];

    systemd.services.proxy-v6-watch = {
      description = "Restart proxy client when IPv6 availability flips";
      after = [ cfg.clientService ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = watchScript;
      };
    };

    systemd.timers.proxy-v6-watch = {
      description = "Poll IPv6 availability for the proxy client";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "60s";
        AccuracySec = "10s";
      };
    };
  };
}
