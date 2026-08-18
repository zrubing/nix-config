{
  config,
  lib,
  pkgs,
  inputs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.multica;
in
{
  options.${namespace}.modules.multica = with lib; {
    enable = mkEnableOption "Enable Multica CLI multi-cluster management tool";

    desktop.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Multica Desktop GUI (${namespace}.multica-desktop)";
    };

    # daemon 拉起 pi/hermes 时，子进程继承 daemon 的环境；systemd user service 不走
    # shell profile，LLM API key 必须用 EnvironmentFile 注入（dsh-web 同款模式，sops 渲染）。
    envFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "systemd EnvironmentFile for multica-daemon (no export prefix, sops-rendered).";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      home.packages = [
        pkgs.${namespace}.multica
      ];

      # config.json 的 token 由 `multica login` 运行时写入，绝不能用 home.file 管理：
      # force=true 会在每次 activation 把 token 抹掉，daemon 立刻陷入 "not authenticated"
      # 崩溃循环（nova13/zen14 均实际发生过）。改用 activation 做 jq merge：
      # 只强制 server_url/app_url，保留 token 等运行时字段。
      home.activation.configureMultica = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        config_file="$HOME/.multica/config.json"
        mkdir -p "$(dirname "$config_file")"
        tmp_file="$(mktemp "$HOME/.multica/config.json.XXXXXX")"

        if [ -f "$config_file" ]; then
          if ! ${pkgs.jq}/bin/jq \
            '. + {server_url: "http://multica-api.local", app_url: "http://multica.local"}' \
            "$config_file" > "$tmp_file"; then
            printf '{"server_url":"http://multica-api.local","app_url":"http://multica.local"}\n' > "$tmp_file"
          fi
        else
          printf '{"server_url":"http://multica-api.local","app_url":"http://multica.local"}\n' > "$tmp_file"
        fi

        chmod 600 "$tmp_file"
        mv -f "$tmp_file" "$config_file"
      '';

      # 把 daemon 交给 systemd 托管，脱离 SSH session 生命周期（session 断开不再杀进程），
      # 也让“升级切二进制”时由 systemd 在 task 之外发 SIGTERM，graceful drain 才能真正生效。
      # 必须 --foreground：否则 multica 自行 daemonize，systemd(Type=simple) 会误判进程退出而反复重启。
      # multica 收 SIGTERM 会 drain in-flight task（实测上限 30s），TimeoutStopSec 给到 60s 避免打断 drain。
      # PATH 必须显式补齐：daemon 靠它发现 agent CLI（pi/hermes 由 systemPackages 放进
      # /run/current-system/sw/bin），而 systemd user service 默认 PATH 极小。
      systemd.user.services.multica-daemon = {
        Unit = {
          Description = "Multica local agent runtime daemon";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };
        Install.WantedBy = [ "default.target" ];
        Service = {
          Type = "simple";
          ExecStart = "${lib.getExe pkgs.${namespace}.multica} daemon start --foreground";
          Environment = [
            "PATH=/run/current-system/sw/bin:/etc/profiles/per-user/%u/bin:%h/.local/bin"
          ];
          Restart = "on-failure";
          RestartSec = 5;
          TimeoutStopSec = "60s";
        }
        // lib.optionalAttrs (cfg.envFile != null) {
          EnvironmentFile = cfg.envFile;
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.desktop.enable) {
      home.packages = [
        pkgs.${namespace}.multica-desktop
      ];

      home.file.".multica/desktop.json" = {
        force = true;
        text = builtins.toJSON {
          schemaVersion = 1;
          apiUrl = "http://multica-api.local";
          wsUrl = "ws://multica-api.local/ws";
          appUrl = "http://multica.local";
        };
      };
    })
  ];
}
