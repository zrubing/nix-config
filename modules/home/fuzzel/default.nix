{
  lib,
  config,
  pkgs,
  namespace,
  inputs,
  ...
}:

let
  cfg = config.${namespace}.modules.fuzzel;
in
{
  options.${namespace}.modules.fuzzel = {
    enable = lib.mkEnableOption "fuzzel application launcher";
  };

  config = lib.mkIf cfg.enable {
    programs.fuzzel = {
      enable = true;
      settings = {
        main = {
          terminal = "${lib.getExe pkgs.foot}";
          font = "JetBrains Mono,Noto Sans CJK SC:size=12";
          prompt = "❯ ";
          icon-theme = "Papirus-Dark";
          lines = 15;
          width = 60;
          horizontal-pad = 20;
          vertical-pad = 15;
          inner-pad = 10;
          line-height = 22;
          icons-enabled = true;
          placeholder = "Type to search...";
          };
        colors = {
          background = "1e1e2eff";
          text = "cdd6f4ff";
          match = "89b4faff";
          selection = "45475a99";
          selection-text = "cdd6f4ff";
          border = "6c7086ff";
          prompt = "fab387ff";
          input = "a6e3a1ff";
        };
        border = {
          width = 2;
          radius = 12;
        };
      };
    };

    # 创建一些实用的 fuzzel 脚本
    home.packages = [
      (pkgs.writeShellScriptBin "fuzzel-launcher" ''
        #!/usr/bin/env bash
        # 基于 fuzzel 的应用启动器

        # 获取所有可执行文件
        get_apps() {
          if command -v desktop-file-validate >/dev/null 2>&1; then
            # 优先使用 desktop 文件
            find /usr/share/applications ~/.local/share/applications -name "*.desktop" 2>/dev/null | \
            xargs grep -l "NoDisplay=false" 2>/dev/null | \
            while read -r desktop; do
              if [[ -f "$desktop" ]]; then
                name=$(grep "^Name=" "$desktop" | head -1 | cut -d= -f2- || basename "$desktop" .desktop)
                exec=$(grep "^Exec=" "$desktop" | head -1 | cut -d= -f2- | cut -d' ' -f1)
                if [[ -n "$name" && -n "$exec" ]]; then
                  echo "$name"
                fi
              fi
            done | sort -u
          else
            # 回退到 PATH 搜索
            get_path_commands | sort -u
          fi
        }

        # 获取 PATH 中的命令
        get_path_commands() {
          echo "$PATH" | tr ':' '\n' | while read -r dir; do
            [[ -d "$dir" ]] && find "$dir" -maxdepth 1 -type f -executable -printf "%f\n" 2>/dev/null
          done
        }

        # 主程序
        selection=$(printf "$(get_apps)" | fuzzel --dmenu --prompt "应用: ")

        if [[ -n "$selection" ]]; then
          # 首先尝试作为命令直接执行
          if command -v "$selection" >/dev/null 2>&1; then
            exec "$selection" &
          else
            # 尝试查找 desktop 文件并执行
            desktop_file=$(find /usr/share/applications ~/.local/share/applications -name "*.desktop" 2>/dev/null | \
              xargs grep -l "Name=$selection" 2>/dev/null | head -1)

            if [[ -n "$desktop_file" ]]; then
              exec=$(grep "^Exec=" "$desktop_file" | head -1 | cut -d= -f2- | cut -d' ' -f1)
              if [[ -n "$exec" ]]; then
                exec "$exec" &
              fi
            fi
          fi
        fi
      '')

    (pkgs.writeShellScriptBin "fuzzel-file-chooser" ''
        #!/usr/bin/env bash
        # 基于 fuzzel 的文件选择器

        if [[ $# -eq 0 ]]; then
          base_dir="$HOME"
        else
          base_dir="$1"
        fi

        while true; do
          # 使用 fd 进行文件搜索（如果可用），否则使用 find
          if command -v fd >/dev/null 2>&1; then
            selection=$(fd --type f --hidden --follow . "$base_dir" 2>/dev/null | \
              fuzzel --dmenu --prompt "文件: " || break)
          else
            selection=$(find "$base_dir" -type f -not -path '*/\.*' 2>/dev/null | \
              fuzzel --dmenu --prompt "文件: " || break)
          fi

          if [[ -n "$selection" ]]; then
            if [[ -f "$selection" ]]; then
              # 输出选择的文件路径
              echo "$selection"
              break
            elif [[ -d "$selection" ]]; then
              base_dir="$selection"
            fi
          else
            break
          fi
        done
      '')

      (pkgs.writeShellScriptBin "fuzzel-ssh" ''
        #!/usr/bin/env bash
        # SSH 连接选择器

        SSH_CONFIG="$HOME/.ssh/config"
        TERM="foot"

        construct_list() {
          if [[ -f "$SSH_CONFIG" ]]; then
            while read -r host; do
              if [[ -n "$host" && "$host" != "*" ]]; then
                hostname=$(awk -v h="$host" '
                  /^Host / { in_host = ($2 == h) }
                  in_host && /^[[:space:]]*HostName/ { print $2; exit }
                  /^Host / && $2 != h { in_host = 0 }
                ' "$SSH_CONFIG")
                hostname="${hostname:-$host}"

                user=$(awk -v h="$host" '
                  /^Host / { in_host = ($2 == h) }
                  in_host && /^[[:space:]]*User/ { print $2; exit }
                  /^Host / && $2 != h { in_host = 0 }
                ' "$SSH_CONFIG")
                user="${user:-$USER}"

                echo "󰒋  $host ($user@$hostname)"
              fi
            done < <(awk '/^Host [^*]/ {print $2}' "$SSH_CONFIG")
          fi
        }

        selection=$(printf "$(construct_list)" | fuzzel --dmenu --prompt="SSH: " | awk '{print $2}')

        if [[ -n "$selection" ]]; then
          exec $TERM -e ssh "$selection"
        fi
      '')

    (pkgs.writeShellScriptBin "fuzzel-test-chinese" ''
        #!/usr/bin/env bash
        # 测试 fuzzel 中文输入支持

        echo "测试 fuzzel 中文输入支持" | fuzzel --dmenu --prompt "中文测试: "
      '')

    (pkgs.writeShellScriptBin "fuzzel-calc" ''
        #!/usr/bin/env bash
        # 简单计算器

        while true; do
          expression=$(echo "" | fuzzel --dmenu --prompt="计算: " --password)

          if [[ -n "$expression" ]]; then
            # 使用 bc 进行计算
            result=$(echo "$expression" | bc -l 2>/dev/null)
            if [[ $? -eq 0 ]]; then
              echo "$result" | wl-copy 2>/dev/null || echo "$result"

              # 显示结果
              (echo "结果: $result" | fuzzel --dmenu --prompt="结果: " --no-run) || break
            else
              echo "计算错误" | fuzzel --dmenu --prompt="错误: " --no-run
            fi
          else
            break
          fi
        done
      '')
    ];

  };
}
