{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.multica;
in
{
  options.${namespace}.modules.multica = with lib; {
    enable = mkEnableOption "Enable Multica CLI multi-cluster management tool";

    daemon.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Run the local agent runtime daemon on this machine.";
    };

    desktop.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Multica Desktop GUI (${namespace}.multica-desktop)";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      home.packages = [
        pkgs.${namespace}.multica
      ];

      # `~/.multica/config.json` 同时存 server_url 和登录 token，token 每次登录都会变。
      # 用 home.file 软链到 nix store 会让这个文件只读，CLI 写不进 token，
      # daemon 于是永远启动即失败并报 "not authenticated"。
      # 所以不再托管该文件：默认地址走环境变量，文件留给 CLI 自己维护。
      home.sessionVariables = {
        MULTICA_SERVER_URL = "http://multica-api.local";
        MULTICA_APP_URL = "http://multica.local";
      };

      # 迁移：旧配置留下的是指向 nix store 的符号链接，删掉，让 CLI 能重建真实文件。
      home.activation.multicaConfigOwnership = ''
        cfg="${config.home.homeDirectory}/.multica/config.json"
        if [ -L "$cfg" ]; then
          rm -f "$cfg"
        fi
      '';

    })

    (lib.mkIf (cfg.enable && cfg.daemon.enable) {
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
            "MULTICA_SERVER_URL=http://multica-api.local"
            "MULTICA_APP_URL=http://multica.local"
          ];
          Restart = "on-failure";
          RestartSec = 5;
          TimeoutStopSec = "60s";
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
