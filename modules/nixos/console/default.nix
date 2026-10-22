{
  config,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.console;

  # 合盖熄屏：轮询 ACPI lid 状态，关盖把背光关掉，开盖恢复原来的亮度。
  # 机器上没有桌面环境，logind 的 HandleLidSwitch 只有
  # ignore/suspend/poweroff 几种动作，做不了「只关屏」，所以自己做。
  # 目标机器是 k0s worker + 中转节点：合盖必须继续跑，不能 suspend。
  lidBlankScript = pkgs.writeShellScript "lid-backlight" ''
    set -eu

    bl=$(ls -d /sys/class/backlight/* 2>/dev/null | head -1 || true)
    lid=$(ls /proc/acpi/button/lid/*/state 2>/dev/null | head -1 || true)
    if [ -z "$bl" ] || [ -z "$lid" ]; then
      echo "no backlight or no lid switch on this machine" >&2
      exec sleep infinity
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
          echo "$saved" > "$bl/brightness"
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

    lidBlank = mkOption {
      type = types.bool;
      default = true;
      description = ''
        合盖关背光、开盖恢复。机器不会 suspend —— 适合无桌面环境但需要常驻的节点。
        没有 ACPI lid 设备时本服务空转，不影响启动。
      '';
    };
  };

  config = lib.mkIf cfg.enable {
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
      '';
    };

    # /sys/class/backlight/*/brightness 默认 root:root 0644，而且不在 udev 的
    # uaccess 名单里，所以普通用户改不了亮度（实测 Permission denied）。
    # 交给 video 组写，配合 users.users.<name>.extraGroups = [ "video" ]。
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="backlight", RUN+="${pkgs.coreutils}/bin/chgrp video /sys/class/backlight/%k/brightness", RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/class/backlight/%k/brightness"
    '';

    environment.systemPackages = [ pkgs.brightnessctl ];

    systemd.services.lid-backlight = lib.mkIf cfg.lidBlank {
      description = "Turn the panel backlight off while the lid is closed";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = lidBlankScript;
        Restart = "always";
        RestartSec = 3;
      };
    };
  };
}
