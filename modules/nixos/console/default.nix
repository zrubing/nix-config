{
  config,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.console;

  # kmscon 只认固定这几组键（源码 src/kmscon_conf.c 的 CONF_OPTION_COLOR）。
  # 值格式是三个 0-255 的十进制数，逗号分隔，不是十六进制。
  paletteNames = [
    "black"
    "dark-grey"
    "light-grey"
    "white"
    "red"
    "light-red"
    "green"
    "light-green"
    "yellow"
    "light-yellow"
    "blue"
    "light-blue"
    "magenta"
    "light-magenta"
    "cyan"
    "light-cyan"
    "foreground"
    "background"
  ];

  paletteLines = lib.concatMapStringsSep "\n" (
    name: "palette-${name}=${lib.concatMapStringsSep "," toString cfg.palette.${name}}"
  ) (lib.attrNames cfg.palette);

  # 面板管理与合盖熄屏，一个进程搞定。机器上没有桌面环境，logind 的
  # HandleLidSwitch 只有 ignore/suspend/poweroff 几种动作，做不了「只关屏」，
  # 所以自己轮询。/etc/systemd/logind.conf 里三条 lid 动作都是 ignore：这台是
  # k0s worker + 中转节点，合盖必须继续跑。
  #
  # 两个实测过的坑，都在这段里做掉：
  #
  #   1. 开机后 amdgpu 的背光值默认是 655/65535（约 1%，几乎全黑）。不主动设，
  #      每次重启屏幕都是黑的 —— 所以先按配置的百分比设置初始亮度。
  #   2. 背光节点不是开机即有：本机实测 02:49:50 服务启动、02:49:55 设备才出现，
  #      差 5 秒。旧版直接 ls 一次、失败就 sleep infinity，于是合盖熄屏从未生效。
  #      改成有上限的等待。
  backlightScript = pkgs.writeShellScript "backlight" ''
    set -eu

    bl=
    lid=
    i=0
    while [ "$i" -lt 60 ]; do
      bl=$(ls -d /sys/class/backlight/* 2>/dev/null | head -1 || true)
      lid=$(ls /proc/acpi/button/lid/*/state 2>/dev/null | head -1 || true)
      [ -n "$bl" ] && break
      i=$((i + 1))
      sleep 1
    done

    # 没有背光的机器（台式机/无面板）到这里就结束，不算失败。
    if [ -z "$bl" ]; then
      echo "no backlight device after 60s; nothing to manage" >&2
      exit 0
    fi

    echo 0 > "$bl/bl_power" 2>/dev/null || true
    max=$(cat "$bl/max_brightness")
    echo $(( max * ${toString cfg.initialBrightnessPercent} / 100 )) > "$bl/brightness"

    # 没有 lid 开关就不必进轮询。
    if [ -z "$lid" ]; then
      echo "no lid switch; initial brightness set, exiting" >&2
      exit 0
    fi

    saved=
    while :; do
      state=$(sed -n 's/^state:[[:space:]]*//p' "$lid")
      case "$state:$saved" in
        closed:)
          saved=$(cat "$bl/brightness")
          echo 0 > "$bl/brightness"
          echo 1 > "$bl/bl_power" 2>/dev/null || true
          ;;
        open:?*)
          echo 0 > "$bl/bl_power" 2>/dev/null || true
          # 面板被外部改过就尊重外部值，不覆盖回去。
          [ "$(cat "$bl/brightness")" = 0 ] && echo "$saved" > "$bl/brightness"
          saved=
          ;;
      esac
      sleep 1
    done
  '';
in
{
  options.${namespace}.console = with lib; {
    enable = mkEnableOption "userspace console (kmscon) with fonts, colors and CJK";

    fontSize = mkOption {
      type = types.ints.positive;
      default = 18;
      description = "控制台字号（像素）。";
    };

    palette = mkOption {
      type = types.attrsOf (types.listOf (types.ints.between 0 255));
      default = {
        # Gruvbox Dark。kmscon 默认是纯白/纯黑，4096 级灰阶下刺眼且对比过强；
        # 这套在 26px 字号下久看不累。
        black = [ 40 40 40 ];
        dark-grey = [ 146 131 116 ];
        light-grey = [ 168 153 132 ];
        white = [ 235 219 178 ];
        red = [ 204 36 29 ];
        light-red = [ 251 73 52 ];
        green = [ 152 151 26 ];
        light-green = [ 184 187 38 ];
        yellow = [ 215 153 33 ];
        light-yellow = [ 250 189 47 ];
        blue = [ 69 133 136 ];
        light-blue = [ 131 165 152 ];
        magenta = [ 177 98 134 ];
        light-magenta = [ 211 134 155 ];
        cyan = [ 104 157 106 ];
        light-cyan = [ 142 192 124 ];
        foreground = [ 235 219 178 ];
        background = [ 40 40 40 ];
      };
      description = ''
        控制台配色。键必须是 kmscon 认识的那组（见 paletteNames），值是三个
        0-255 的整数，逗号分隔后写进 kmscon.conf（kmscon 不认十六进制）。
        换主题就是整体替换这个 attrset；只写一部分时缺的键保持 kmscon 默认。
      '';
    };

    initialBrightnessPercent = mkOption {
      type = types.ints.between 1 100;
      default = 50;
      description = ''
        开机时把背光设成最大值的百分之多少。

        必须显式设置：amdgpu 开机给的默认值约 1%（实测 655/65535），不设就是黑屏。
        之后用 brightnessctl 临时调，重启回到这个值。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (n: lib.elem n paletteNames) (lib.attrNames cfg.palette);
        message = "console.palette 里有 kmscon 不认识的键；合法键见 paletteNames。";
      }
      {
        assertion = lib.all (n: cfg.palette ? ${n}) paletteNames;
        message = "console.palette 缺键；kmscon 会退回它自己的默认色，混搭会很丑。";
      }
    ];

    # 内核 VT 换成就地渲染的用户态终端：真字体、24 位色、中文、可配色。
    # 仍然保留 6 个 VT，logind 切 VT 时通过 autovt@.service 别名拉起。
    services.kmscon = {
      enable = true;
      hwRender = true;
      term = "xterm-256color";
      fonts = [
        {
          name = "JetBrainsMono Nerd Font";
          package = pkgs.nerd-fonts.jetbrains-mono;
        }
        {
          # 中文靠 pango 逐字回退，排第二个即可。
          name = "Noto Sans Mono CJK SC";
          package = pkgs.noto-fonts-cjk-sans;
        }
      ];
      # 键盘布局沿 services.xserver.xkb（本仓库 locale 模块设为 us），
      # 不用 console.keyMap —— 那是编译好的 keymap 文件路径，kmscon 认的是布局名。
      useXkbConfig = true;
      extraConfig = ''
        font-size=${toString cfg.fontSize}
        ${paletteLines}
      '';
    };

    # /sys/class/backlight/*/brightness 默认 root:root 0644，而且不在 udev 的
    # uaccess 名单里，所以普通用户改不了亮度（实测 Permission denied）。
    # 交给 video 组写，配合 users.users.<name>.extraGroups = [ "video" ]。
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="backlight", RUN+="${pkgs.coreutils}/bin/chgrp video /sys/class/backlight/%k/brightness", RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/class/backlight/%k/brightness"
    '';

    environment.systemPackages = [ pkgs.brightnessctl ];

    systemd.services.backlight = {
      description = "Set initial panel brightness and blank it while the lid is closed";
      wantedBy = [ "multi-user.target" ];
      # 背光由 amdgpu 在 modeset 之后创建，服务必须晚于它；否则只能靠脚本里的
      # 等待兜住。两个都写上：能等就等，等不到再自己轮询。
      after = [ "systemd-udev-settle.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = backlightScript;
        Restart = "always";
        RestartSec = 3;
      };
    };
  };
}
