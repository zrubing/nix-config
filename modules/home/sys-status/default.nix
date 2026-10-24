{
  lib,
  config,
  pkgs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.sys-status;
in
{
  options.${namespace}.modules.sys-status.enable =
    lib.mkEnableOption "one-line system status (battery / load / memory)";

  # 一行系统信息，给「提示符」和「tmux 状态栏」共用。
  #
  # 为什么单独一个模块：两个消费方分属不同模块（bash 的提示符钩子、tmux 的
  # status-right），写在任一边都会让另一边产生隐式依赖 —— 只开 tmux 不开 bash 模块
  # 就会 command not found。这里按开关安装，谁要用就按名字调。
  #
  # 默认关闭：只有无桌面的 tty 机器（nova13）才需要它；zen14 有桌面，电量在桌面上
  # 就能看到，提示符和状态栏再刷一遍只是噪音。两个消费方共用同一个开关，避免出现
  # 「脚本装了但没处用」或「引用了但脚本没装」的半开状态。
  #
  # 没有电池的机器（台式机）直接退出 1：调用方据此决定整段不显示，
  # 而不是打印一行只剩负载/内存的残句。
  config = lib.mkIf cfg.enable {
    home.packages = [
      (pkgs.writeShellScriptBin "sys-status" ''
        set -eu

        bat=
        for b in /sys/class/power_supply/BAT*; do
          [ -r "$b/capacity" ] || continue
          bat=$b
          break
        done
        [ -n "$bat" ] || exit 1

        cap=$(cat "$bat/capacity")
        case "$(cat "$bat/status" 2>/dev/null || echo Unknown)" in
          Charging) icon="+" ;;
          Full) icon="=" ;;
          Discharging) icon="-" ;;
          *) icon="?" ;;
        esac

        read -r l1 _ < /proc/loadavg

        mem=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{
          if (t > 0) printf "%.1f/%.1fG", (t-a)/1048576, t/1048576
        }' /proc/meminfo)

        # 单个 %：tmux 对 #() 的输出不做格式展开，写成 %% 会显示两个百分号。
        printf '%s%s%%  L:%s  M:%s' "$icon" "$cap" "$l1" "$mem"
      '')
    ];
  };
}
