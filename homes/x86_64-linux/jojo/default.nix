{ lib, config, pkgs, namespace, ... }:
let
  lowBatteryScript = pkgs.writeShellApplication {
    name = "low-battery-notify";
    runtimeInputs = with pkgs; [ libnotify coreutils ];
    text = ''
      set -euo pipefail

      CAPACITY_FILE="/sys/class/power_supply/BAT0/capacity"
      STATUS_FILE="/sys/class/power_supply/BAT0/status"
      THRESHOLD=15
      MARKER_DIR="''${XDG_RUNTIME_DIR:-/tmp}/low-battery-notify"
      NOTIFY_GAP=300

      # 没有电池设备（台式机）直接退出
      if [[ ! -f "$CAPACITY_FILE" ]] || [[ ! -f "$STATUS_FILE" ]]; then
        exit 0
      fi

      CAPACITY=$(cat "$CAPACITY_FILE")
      STATUS=$(cat "$STATUS_FILE")

      # 不在放电中或电量高于阈值，重置标记后退出
      if [[ "$STATUS" != "Discharging" ]] || [[ "$CAPACITY" -gt "$THRESHOLD" ]]; then
        rm -f "$MARKER_DIR/last_notify" "$MARKER_DIR/last_capacity"
        exit 0
      fi

      mkdir -p "$MARKER_DIR"
      NOW=$(date +%s)

      LAST_NOTIFY=0
      if [[ -f "$MARKER_DIR/last_notify" ]]; then
        LAST_NOTIFY=$(cat "$MARKER_DIR/last_notify")
      fi

      LAST_CAP=100
      if [[ -f "$MARKER_DIR/last_capacity" ]]; then
        LAST_CAP=$(cat "$MARKER_DIR/last_capacity")
      fi

      # 距上次通知不到5分钟且电量没再降，跳过
      if [[ $((NOW - LAST_NOTIFY)) -lt "$NOTIFY_GAP" ]] && [[ "$CAPACITY" -ge "$LAST_CAP" ]]; then
        exit 0
      fi

      notify-send -u critical \
        "🔋 电量过低" \
        "当前电量 ''${CAPACITY}%，请尽快连接电源！" \
        -i battery-caution \
        -t 10000

      echo "$NOW" > "$MARKER_DIR/last_notify"
      echo "$CAPACITY" > "$MARKER_DIR/last_capacity"
    '';
  };
in
{

  home.stateVersion = "25.11";

  home.packages = [
    pkgs.${namespace}."pv-inspect"
  ];

  programs.k9s = {
    enable = true;
    plugins = {
      pv_inspect = {
        shortCut = "p";
        description = "Inspect PVC with pv_inspect";
        scopes = [ "pvc" ];
        command = "pv_inspect";
        background = false;
        args = [
          "-n"
          "$NAMESPACE"
          "$NAME"
        ];
      };
    };
  };

  internal.javalib.enable = true;

  snowfallorg.user.enable = true;

  # 低电量通知：每分钟检查一次，电量 ≤15% 且未插电时弹窗提醒
  systemd.user.services.low-battery-notify = {
    Unit.Description = "Send notification when battery level is low";
    Service = {
      Type = "oneshot";
      ExecStart = "${lowBatteryScript}/bin/low-battery-notify";
    };
  };

  systemd.user.timers.low-battery-notify = {
    Unit.Description = "Check battery level periodically";
    Timer = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  internal = {

    ccr-router.enable = false;

    #desktop.kde.enable = true;
    desktop.niri.enable = true;
    emacs = {
      enable = true;
      type = "doom";
    };
    terminal = "ghostty";
    ghostty.enable = true;
    gpg.enable = true;
    password-store.enable = true;
    shell = {
      enable = "bash";
      #provider = "MiniMax";
      provider = "GLM";
    };

    cc-proxy.enable = false;
    sops.enable = true;

    bash.enable = true;

    #fish.provider = "MiniMax";
    #fish.provider = "GLM";
    #fish.provider = "Qwen";

    modules = {
      fcitx5.enable = true;
      fuzzel.enable = true;
      packages = {
        enable = true;
        superpowers.enable = false;
      };
      prettier = {
        enable = true;
        nginxPlugin = true;
      };
      tmux.enable = true;
      # eca.enable = true;
    };

    vcs = {
      user = {
        name = "zrubing";
        email = "rubingem@gmail.com";
      };
    };
  };

}
