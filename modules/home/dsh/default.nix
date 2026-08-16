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
          # zai-coding-cn 是 pi-ai 内置 catalog 路由（端点 open.bigmodel.cn/api/coding/paas/v4，
          # thinkingFormat=zai），但 glm-5.3 不在 catalog（最新到 glm-5.2），
          # 故用 models 列表手工声明（与 pi 的 models.json 定义一致）。
          # 注意：models 是替换而非扩充，写列表后 catalog 其它模型不再服务。
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

    # 每个 provider 的 apiKeyEnv 引用的环境变量名 -> 值（通常来自 sops placeholder）。
    # systemd user service 环境极简，必须显式注入；shell 里 source 的 default.env 不会带进来。
    environment = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Environment variables injected into the dsh web service (API keys referenced by apiKeyEnv).";
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
          ] ++ (lib.mapAttrsToList (name: value: "${name}=${value}") cfg.environment);
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    })
  ];
}
