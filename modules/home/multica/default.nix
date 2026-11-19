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

    daemon.configFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Absolute path to a rendered <code>config.json</code> that carries the
        daemon credential (fields <code>server_url</code>, <code>app_url</code>,
        <code>token</code>, <code>workspace_id</code>).

        为什么不能只给 <code>MULTICA_TOKEN</code>：daemon 启动时只读
        <code>~/.multica/config.json</code>，不认环境变量（CLI 的
        <code>auth status</code> 认，daemon 不认，实测直接报
        “not authenticated”）。所以凭据必须以真实文件落到 home 里。

        文件由 unit 的 ExecStartPre 复制（不是 home.file 软链）：软链到 store
        会让 CLI 无法写回 token，而 daemon 运行中确实会重写它。
      '';
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
      # 所以不托管该文件：默认地址走环境变量，文件留给 CLI 自己维护；
      # 需要无人值守登录的机器用 daemon.configFile 由 unit 启动前复制一份进去。
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
          # sops-nix.service 是 Type=oneshot，负责把 secret 渲染到 /run/secrets。
          # 它与 default.target 下的 user service 无排序，缺这条依赖时 daemon 会
          # 先启动、读不到 configFile 里的凭据，然后以 “not authenticated” 反复重启。
          After = [ "network-online.target" ]
            ++ lib.optional (cfg.daemon.configFile != null) "sops-nix.service";
          Wants = [ "network-online.target" ]
            ++ lib.optional (cfg.daemon.configFile != null) "sops-nix.service";
        };
        Install.WantedBy = [ "default.target" ];
        Service = {
          Type = "simple";
          ExecStart = "${lib.getExe pkgs.${namespace}.multica} daemon start --foreground";
          # daemon 只认 ~/.multica/config.json（不认 MULTICA_TOKEN），所以启动前
          # 把渲染好的凭据文件复制进去。必须是复制而不是软链：daemon 运行中会重写
          # 这个文件（token-renewal），指向 store 的软链会写失败。
          ExecStartPre = lib.mkIf (cfg.daemon.configFile != null)
            "${pkgs.bash}/bin/bash -c 'mkdir -p %h/.multica && ${pkgs.coreutils}/bin/install -m 600 ${cfg.daemon.configFile} %h/.multica/config.json'";
          # dsh 的 multica runtime 需要与交互 shell 同一份环境（MCP token 等）：
          # 缺 token 时 MCP 条目的 headers 会退化成 {}，dsh 启动即校验失败，
          # daemon 的 --probe 拿不到结果。
          EnvironmentFile = lib.optional (config.${namespace}.modules.dsh.envFile != null)
            config.${namespace}.modules.dsh.envFile;
          Environment = [
            "PATH=/run/current-system/sw/bin:/etc/profiles/per-user/%u/bin:%h/.local/bin"
            "MULTICA_SERVER_URL=http://multica-api.local"
            "MULTICA_APP_URL=http://multica.local"
            # dsh.env 里带了 HTTP(S)_PROXY，daemon 走代理会拿不到 *.local（502）。
            # 这些变量排在 EnvironmentFile 之后，按 systemd 语义覆盖文件里的值。
            "HTTP_PROXY="
            "HTTPS_PROXY="
            "http_proxy="
            "https_proxy="
            "NO_PROXY=multica.local,multica-api.local,localhost,127.0.0.1,::1"
          ]
          # 顶替 `dsh` 这个可执行文件：multica 的 dsh runtime 改成「把任务挂到
          # 常驻 dsh-web host 上」，不再每任务起一个 dsh 进程。dsh 模块没启用时
          # 保持 null（daemon 回落到 PATH 上的 dsh + profile multica）。
          ++ lib.optionals config.${namespace}.modules.dsh.enable [
            "MULTICA_DSH_PATH=${config.${namespace}.modules.dsh.multicaBridge}/bin/dsh"
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
