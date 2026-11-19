{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.multica;

  # 把 skill 源树（私有 flake input）upsert 进 multica 并绑定 agent。
  # 只读源目录，不碰 skill 正文里的任何凭据；幂等：按 name 查 id，有则 update。
  skillsSync = pkgs.writeScriptBin "multica-skills-sync" ''
    #!${pkgs.python3}/bin/python3
    import json
    import os
    import pathlib
    import subprocess
    import sys

    CLI = os.environ.get("MULTICA_CLI", "multica")


    def run(*args):
        proc = subprocess.run([CLI, *args], capture_output=True, text=True)
        if proc.returncode != 0:
            detail = proc.stderr.strip() or proc.stdout.strip()
            sys.exit("failed: " + " ".join(args) + ": " + detail)
        return proc.stdout


    def read_frontmatter(path):
        name = path.parent.name
        desc = ""
        text = path.read_text()
        if text.startswith("---"):
            _, _, rest = text.partition("---")
            block, _, _ = rest.partition("---")
            for line in block.splitlines():
                key, sep, value = line.partition(":")
                if not sep:
                    continue
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if key == "name" and value:
                    name = value
                elif key == "description":
                    desc = value
        return name, desc


    def main():
        if len(sys.argv) < 2:
            sys.exit("usage: multica-skills-sync <source-dir> [agent ...]")
        src = pathlib.Path(sys.argv[1])
        agents = sys.argv[2:]
        files = [
            p / "SKILL.md"
            for p in sorted(src.iterdir())
            if p.is_dir() and (p / "SKILL.md").exists()
        ]
        if not files:
            sys.exit("no SKILL.md under " + str(src))

        existing = {
            s["name"]: s["id"]
            for s in json.loads(run("skill", "list", "--output", "json") or "[]")
        }
        agent_ids = {
            a["name"]: a["id"]
            for a in json.loads(run("agent", "list", "--output", "json") or "[]")
        }

        for md in files:
            name, desc = read_frontmatter(md)
            if name in existing:
                sid = existing[name]
                run("skill", "update", sid, "--content-file", str(md),
                    "--description", desc, "--output", "json")
                print("updated " + name + " " + sid)
            else:
                sid = json.loads(run("skill", "create", "--name", name,
                                     "--description", desc, "--content-file", str(md),
                                     "--output", "json"))["id"]
                print("created " + name + " " + sid)
            for agent in agents:
                aid = agent_ids.get(agent)
                if not aid:
                    print("warn: agent not found: " + agent, file=sys.stderr)
                    continue
                run("agent", "skills", "add", aid, "--skill-ids", sid,
                    "--output", "json")
                print("assigned " + name + " -> " + agent)


    main()
  '';
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

    # skill 的正文是内部 runbook（issuer、集群名、路径），不进本仓库明文：
    # 源文件放在私有 flake input 里，这里只引用钉住的 store 路径，激活后推给 multica。
    skills = {
      enable = mkEnableOption "Push the pinned agent-skills source into Multica";

      source = mkOption {
        type = types.path;
        description = ''
          Skill source tree: 一个子目录一个 skill，正文是该目录下的
          <code>SKILL.md</code>（frontmatter 带 name / description）。
        '';
      };

      agents = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Skill 要绑定到的 agent 名字（multica 里的 agent.name）。";
      };
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
          # dsh runtime 走 dsh 模块产出的分流 shim（basename 必须是 dsh）：
          #   --list-models → 桥（常驻 host 的模型表，已裁到 48 KiB）
          #   --stdio       → 原生 dsh，每任务一个进程
          # 0.11 起任务里的 MULTICA_TOKEN 必须是 task-scoped `mat_`，bridge 把任务
          # 挂到常驻 host 上拿不到任务 env，agent 在任务里执行 multica CLI 会失败
          # （2026-11-19 实测，nova13 任务 01a1f3d4）。原生 runtime 能拿到 mat_ 与
          # 任务 cwd；只有模型发现继续借 host，避开原生 113 KB 超单帧上限的问题。
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
          ++ lib.optionals config.${namespace}.modules.dsh.enable [
            "MULTICA_DSH_PATH=${config.${namespace}.modules.dsh.multicaRuntimeShim}/bin/dsh"
          ];
          Restart = "on-failure";
          RestartSec = 5;
          TimeoutStopSec = "60s";
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.skills.enable) {
      # 把钉住的 skill 源树 upsert 进 multica，并绑定到指定 agent。
      # 由 unit 的 ExecStart 参数驱动：skill 内容变（store 路径变）→ unit 变 → switch 时重跑。
      systemd.user.services.multica-skills-sync = {
        Unit = {
          Description = "Push pinned agent skills into Multica";
          # 依赖 daemon：config.json 由 daemon 的 ExecStartPre 从 sops 渲染路径复制过来，
          # 没有它 CLI 会报 not authenticated。
          After = [ "multica-daemon.service" ];
          Wants = [ "multica-daemon.service" ];
        };
        Service = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${skillsSync}/bin/multica-skills-sync ${cfg.skills.source} ${
            lib.escapeShellArgs cfg.skills.agents
          }";
          Environment = [
            "PATH=/run/current-system/sw/bin:/etc/profiles/per-user/%u/bin:%h/.local/bin"
            "MULTICA_CLI=${lib.getExe pkgs.${namespace}.multica}"
            # 同 daemon：dsh.env 带的代理会让 CLI 访问 *.local 变成 502。
            "HTTP_PROXY="
            "HTTPS_PROXY="
            "http_proxy="
            "https_proxy="
            "NO_PROXY=multica.local,multica-api.local,localhost,127.0.0.1,::1"
          ];
        };
        Install.WantedBy = [ "default.target" ];
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
