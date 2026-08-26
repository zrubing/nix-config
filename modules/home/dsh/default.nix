{
  config,
  lib,
  pkgs,
  inputs,
  system,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.dsh;
  dshPackage = inputs.llm-agents.packages.${system}.dsh;
  # activation 跑在系统级 home-manager-jojo.service 里，unit 的 PATH 只有
  # coreutils/grep 等基础包（hm-setup-env 不导入用户 session 的 PATH），
  # dsh plugin 内部 spawn 的 pnpm 找不到 → 安装静默失败（WARN 进系统 journal）。
  # 所有会调 dsh plugin 的 activation 块必须先补上用户 profile bin。
  username = config.snowfallorg.user.name;
  userBin = "/etc/profiles/per-user/${username}/bin";

  # 本地 dsh 插件：中和 MCP 工具描述带进 prompt section 的未注册 {{...}} 组
  # （如 apipost get_target_detail 的字面示例 {{paramName}}），否则
  # dsh-system-prompt 严格渲染器抛 "malformed prompt variable reference"
  # 导致整轮对话失败（上游已知问题 #711，rc.2 无转义语法未修）。
  # 已注册变量（model/cwd 等）保留插值；单测见仓库 .braces-sanitize-test.mjs。
  bracesSanitizePlugin = pkgs.runCommand "dsh-braces-sanitize" { } ''
    mkdir -p $out
    cp ${./plugins/braces-sanitize/package.json} $out/package.json
    cp ${./plugins/braces-sanitize/index.js} $out/index.js
  '';

  # 静态 patch 层：cordis.patch.yml 只被 dsh 只读加载（从不写回），
  # 所以可以安全地由 nix 托管（软链接到 store）。provider 模型路由放这里。
  providerPatch = pkgs.writeText "dsh-cordis.patch.yml" ''
    - id: llm-pi-ai
      config:
        providers:
          deepseek:
            apiKeyEnv: DEEPSEEK_API_KEY
          openai:
            apiKeyEnv: OPENAI_API_KEY
          # opencode-go 是 pi-ai 内置 catalog 路由（OpenCode Zen Go 网关，
          # 含 deepseek-v4-pro/flash、glm-5.2、kimi-k3、qwen3.7 等模型），
          # 认证环境变量 OPENCODE_API_KEY 与 jojo home 注入一致。
          opencode-go:
            apiKeyEnv: OPENCODE_API_KEY
          # openrouter 是 pi-ai 内置 catalog 路由（https://openrouter.ai/api/v1，
          # openai-completions），catalog 内置 276 个模型，无需手工声明 models。
          openrouter:
            apiKeyEnv: OPENROUTER_API_KEY
          # stealth/ox-alpha 不在内嵌 pi-ai 0.82.1 的 openrouter catalog 快照里
          # （pi 0.84.3 打包的新快照才有）。modelOverrides 不能凭空创建模型 id
          # （llm-pi-ai 源码强制校验），models 全量替换又不现实，故按 runinfra
          # 模式开独立路由，复用同一把 OPENROUTER_API_KEY。
          ox-alpha:
            apiKeyEnv: OPENROUTER_API_KEY
            displayName: OpenRouter (ox-alpha)
            api: openai-completions
            baseURL: https://openrouter.ai/api/v1
            models:
              - id: stealth/ox-alpha
                name: ox-alpha (stealth)
                contextWindow: 1000000
                maxTokens: 131072
                input: [text]
          # zai-coding-cn 是 pi-ai 内置 catalog 路由（端点 open.bigmodel.cn/api/coding/paas/v4，
          # thinkingFormat=zai），但 glm-5.3 不在 catalog（最新到 glm-5.2），
          # 故用 models 列表手工声明（与 pi 的 models.json 定义一致）。
          # 注意：models 是替换而非扩充，写列表后 catalog 其它模型不再服务。
          # runinfra 是自定义 provider（不在 pi-ai catalog），照搬 pi 插件
          # monotykamary/pi-runinfra-provider 的定义：openai-completions 网关，
          # 4 个模型全部显式声明（含 baseUrl/api，新键无默认可继承）。
          # key 来自 pi auth.json 的 runinfra 条目（已迁入 sops secrets/env.yaml）。
          runinfra:
            apiKeyEnv: RUNINFRA_GATEWAY_KEY
            displayName: RunInfra
            # 注意 schema：api/baseURL 在 provider 层（models 条目不接受这些字段）；
            # cost 也不在 patch schema 里（仅 UI 成本展示用，省略不影响功能）。
            api: openai-completions
            baseURL: https://api.runinfra.ai/v1
            models:
              - id: deepseek-v4-flash
                name: DeepSeek V4 Flash (RunInfra)
                contextWindow: 1048576
                maxTokens: 32768
                input: [text]
              - id: deepseek-v4-pro
                name: DeepSeek V4 Pro (RunInfra)
                contextWindow: 1048576
                maxTokens: 32768
                input: [text]
              - id: qwen3-8-2-4t-a95b
                name: Qwen3.8 2.4T A95B (RunInfra)
                contextWindow: 262144
                maxTokens: 32768
                input: [text]
              - id: qwen3-8-27b
                name: Qwen3.8 27B (RunInfra)
                contextWindow: 262144
                maxTokens: 32768
                input: [text]
          zai-coding-cn:
            apiKeyEnv: ZAI_CODING_CN_API_KEY
            models:
              - id: glm-5.3
                name: GLM-5.3
                contextWindow: 1000000
                maxTokens: 131072
                reasoningEfforts:
                  low: high
                  medium: high
                  high: high
                  max: max
                compat:
                  thinkingFormat: zai

    # ApiPost 开放平台 MCP：远程 streamable-http server，认证走 api-token 头。
    # token 由 clan vars 加密管理（apipost-mcp-token generator），经 home sops
    # 解密渲染进 dsh.env，dsh-web 服务 EnvironmentFile 注入后在此运行时求值，
    # 本 patch 文件不含明文密钥。插件包由下方 activation 装入 web profile；
    # headless 未装此包，加载该条目时仅告警跳过（failOnStartupError 默认 false）。
    - insert:
        - id: mcp-apipost
          name: '@deepseek-ai/dsh-mcp-client'
          config:
            serverName: apipost
            transport: streamable-http
            url: https://open.apipost.net/mcp
            headers:
              api-token: !!js process.env.APIPOST_MCP_TOKEN

    # 工具描述花括号清洗（见上方 bracesSanitizePlugin 注释）。waterfall listener
    # 在 next() 之后改写权威 assembly，注册顺序无关；headless 未装包时本条目
    # 加载仅告警跳过。
    - insert:
        - id: mcp-braces-sanitize
          name: dsh-braces-sanitize
          config: {}
  '';
in
{
  options.${namespace}.modules.dsh = with lib; {
    enable = mkEnableOption "DeepSeek Harness (dsh)";

    web.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Host the dsh web UI as a systemd user service.";
    };
    web.host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind host for the dsh web UI.";
    };
    web.port = mkOption {
      type = types.port;
      default = 3080;
      description = "Listen port for the dsh web UI.";
    };
    web.trustedHosts = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra authorities the /api browser-trust fence accepts (host or host:port). Needed when accessing via a .local name from another machine.";
    };

    plugins.opencodeModels.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install wyouwd1/dsh-opencode-models into the web profile. Provides a
        settings section that live-syncs OpenCode Zen free/go tier model lists
        (covers models missing from the bundled pi-ai catalog, e.g. ox-alpha).
      '';
    };

    plugins.webAuth.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install GDWhisper/dsh-web-startup-auth into the web profile: login
        page + password auth, releases the loopback-only privileged RPCs
        (settings.*, credentials.*, llm.discoverModels) for authenticated
        callers, and overrides the frontend connection.isLoopback gate so the
        settings mirror runs in host mode — fixes "settings are unavailable
        in this browser" when the UI is opened via a non-loopback hostname.
      '';
    };

    # systemd user service 环境极简，必须显式注入；shell 里 source 的 default.env 不会带进来。
    # 注意：不能用 Environment = [ "KEY=${config.sops.placeholder...}" ] —— placeholder 是
    # 求值期的占位符字符串，写入单元后不会被解密。必须走 sops.templates 生成 env 文件，
    # 再由 EnvironmentFile 读入（激活时 sops-nix 把 placeholder 替换为真实值）。
    envFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "EnvironmentFile for the dsh web service (sops template output).";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      home.packages = [ dshPackage ];

      # 静态配置走 cordis.patch.yml（dsh 只读、应用所有 profile），模型路由声明在这里；
      # settings.yaml 留给 dsh 动态管理（Web UI 的 provider 改动 / onboarding 状态），
      # patch 层是 base，settings 分节按提供方合并覆盖，互不冲突。
      home.file.".dsh/cordis.patch.yml" = {
        source = providerPatch;
        force = true;
      };
    })

    (lib.mkIf (cfg.enable && cfg.web.enable) {
      # 参考 multica-daemon：交给 systemd 托管，脱离 SSH session 生命周期。
      systemd.user.services.dsh-web = {
        Unit = {
          Description = "DeepSeek Harness web UI";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };
        Install.WantedBy = [ "default.target" ];
        Service = {
          Type = "simple";
          ExecStart =
            "${lib.getExe dshPackage} web --host ${cfg.web.host} --port ${toString cfg.web.port}"
            + (lib.concatMapStrings (h: " --trusted-host ${h}") cfg.web.trustedHosts);
          Environment = [
            "PATH=/run/current-system/sw/bin:/etc/profiles/per-user/%u/bin:%h/.local/bin"
          ];
          Restart = "on-failure";
          RestartSec = 5;
        }
        // lib.optionalAttrs (cfg.envFile != null) {
          EnvironmentFile = cfg.envFile;
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.plugins.opencodeModels.enable) {
      # dsh 插件 = 往 ~/.dsh/profiles/web 这个 pnpm 项目里加依赖（dsh plugin add 即
      # pnpm add）。不能用 home.file 静态接管 package.json：它是 dsh/pnpm 的活文件
      # （Web UI 装插件也会写它），同 multica config.json 教训，走 activation 幂等安装。
      # 钉在 main HEAD（9f6451a）：v0.1.0 的 settings section 在 dsh 0.1.1-rc.2 下渲染
      # 空白（干净环境冒烟测试复现），main 已修复。首次安装需联网，失败仅告警不阻塞激活。
      home.activation.configureDshOpencodeModels = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="github:wyouwd1/dsh-opencode-models#9f6451ac58885b39d038e085d5475467f2746e97"
        if ! grep -q "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            systemctl --user try-restart dsh-web.service 2>/dev/null || true
          else
            echo "WARN: dsh-opencode-models 安装失败（离线？），下次重建重试"
          fi
        fi
      '';
    })

    (lib.mkIf (cfg.enable && cfg.plugins.webAuth.enable) {
      # 同 opencodeModels：插件 = profile 的 pnpm 依赖，走 activation 幂等安装。
      # 凭据存在 ~/.dsh/web-auth.json（插件用 $HOME 而非 DSH_HOME 定位）。
      home.activation.configureDshWebAuth = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="dsh-web-startup-auth@0.1.2"
        if ! grep -q "dsh-web-startup-auth" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            systemctl --user try-restart dsh-web.service 2>/dev/null || true
          else
            echo "WARN: dsh-web-startup-auth 安装失败（离线？），下次重建重试"
          fi
        fi
      '';
    })

    (lib.mkIf cfg.enable {
      # ApiPost MCP 桥接：把 @deepseek-ai/dsh-mcp-client 装入 web profile，
      # 配合 cordis.patch.yml 里 mcp-apipost 插件条目（token 走环境变量）。
      # 同上走 activation 幂等安装；安装成功后重启服务让插件生效。
      home.activation.configureDshMcpClient = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="@deepseek-ai/dsh-mcp-client@0.0.1-rc.1"
        if ! grep -q "@deepseek-ai/dsh-mcp-client" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            systemctl --user try-restart dsh-web.service 2>/dev/null || true
          else
            echo "WARN: dsh-mcp-client 安装失败（离线？），下次重建重试"
          fi
        fi
      '';
    })

    (lib.mkIf cfg.enable {
      # 花括号清洗插件：源码在 plugins/braces-sanitize/，nix 打包成只读 store path
      # 后以 file: 协议装入 web profile。want 含 store hash，插件内容变更时 spec
      # 随之变化 → grep 不命中 → 自动重装；未变则跳过。
      home.activation.configureDshBracesSanitize = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="file://${bracesSanitizePlugin}"
        if ! grep -qF "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            systemctl --user try-restart dsh-web.service 2>/dev/null || true
          else
            echo "WARN: dsh-braces-sanitize 安装失败（离线？），下次重建重试"
          fi
        fi
      '';
    })
  ];
}
