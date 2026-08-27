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

  # ── runinfra models adapter ───────────────────────────────────────────
  # 单一数据源 = pi 扩展 monotykamary/pi-runinfra-provider（flake input
  # pi-runinfra-provider-src，flake=false 源码树）。pi 侧扩展安装
  # （modules/home/pi 的 runinfraPackage）与 dsh 侧本清单共用 flake.lock
  # 同一 rev：nix flake update pi-runinfra-provider-src → rebuild，两边同步。
  #
  # 合并管线复刻扩展 index.ts buildModels：base(models.json) → apply
  # patch.json（compat 一层深合并）→ merge custom-models.json（覆盖同 id）。
  # deprecated-models.json 是 pi 运行时的 grace-period 概念，不进 dsh 静态清单。
  #
  # 字段映射（dsh-llm-pi-ai 0.1.1-rc.2 schema + openai-completions compat
  # 门控，store 内 lib/index.js 实测）：
  #   id/name/contextWindow/maxTokens/input 直通；
  #   thinkingLevelMap → reasoningEfforts（level→wire 值，级别枚举一致；
  #     只声明了 off 的表按 dsh 规则视为非推理模型，省略字段）；
  #   compat 仅保留 openai-completions 门控 offer 且 dsh compatProfile
  #   认识的字段；cost 不在 dsh patch schema，丢弃。
  runinfraSrc = inputs.pi-runinfra-provider-src;
  # dsh-llm-pi-ai 级别枚举（lib/index.js 实测）；adapter 与下方 emitter 共用
  thinkingLevels = [ "off" "minimal" "low" "medium" "high" "xhigh" "max" ];
  # openai-completions 门控 offer 且 dsh compatProfile 认识的字段白名单
  allowedCompat = [
    "thinkingFormat" "supportsReasoningEffort" "supportsDeveloperRole"
    "supportsStore" "maxTokensField"
    "requiresReasoningContentOnAssistantMessages" "chatTemplateKwargs"
  ];
  runinfraModels =
    let
      base = lib.importJSON (runinfraSrc + "/models.json");
      patch = lib.importJSON (runinfraSrc + "/patch.json");
      custom = lib.importJSON (runinfraSrc + "/custom-models.json");

      # index.ts applyPatch：标量字段覆盖，compat 浅深合并（一层）
      applyPatch = model: p:
        model
        // lib.optionalAttrs (p ? name) { name = p.name; }
        // lib.optionalAttrs (p ? reasoning) { reasoning = p.reasoning; }
        // lib.optionalAttrs (p ? input) { input = p.input; }
        // lib.optionalAttrs (p ? contextWindow) { contextWindow = p.contextWindow; }
        // lib.optionalAttrs (p ? maxTokens) { maxTokens = p.maxTokens; }
        // lib.optionalAttrs (p ? thinkingLevelMap) { thinkingLevelMap = p.thinkingLevelMap; }
        // lib.optionalAttrs (p ? compat) { compat = (model.compat or {}) // p.compat; };

      # index.ts buildModels 等价：patch 后 custom 覆盖同 id，保持声明顺序
      # （base 在前、custom 新增在后；同 id 以列表中靠后者 = custom 为准）
      applyTo = m: if (builtins.hasAttr m.id patch) then applyPatch m (patch.${m.id}) else m;

      # dsh 侧本地补充：网关已上线 glm-5-3-flash（2026-08-27 live /v1/models 实测，
      # id 是连字符 glm-5-3-flash，context 1M；pi 侧扩展经 live discovery 已能取到），
      # 但扩展内置 catalog（models.json 10 模型）尚未注册 → 临时在此补齐。
      # wire 对齐 zai-coding-cn 的 glm-5.3-flash（thinkingFormat: zai；探针实测网关
      # 接受 thinking{type,clear_thinking}+reasoning_effort，均 200 + reasoning 字段）。
      # 上游一旦注册，knownIds 命中 → effectiveExtras 过滤掉本条，自动回归单一数据源。
      # 网关强制 max_tokens <= 32768（2026-08-27 实测 131072 → 400
      # "Too big: expected number to be <=32768"；/v1/models 报的
      # max_output_tokens=1048576 是上限声明非请求限制）→ 取 32768。
      # supportsDeveloperRole: false 与上游 models.json 四个 base 模型一致
      # （网关 role 白名单只有 system/user/assistant/tool，实测 400）。
      extraModels = [
        {
          id = "glm-5-3-flash";
          name = "GLM-5.3 Flash";
          contextWindow = 1048576;
          maxTokens = 32768;
          input = [ "text" ];
          thinkingLevelMap = { low = "high"; medium = "high"; high = "high"; max = "max"; };
          compat = { thinkingFormat = "zai"; supportsDeveloperRole = false; };
        }
      ];
      orderedBase = lib.map applyTo base;
      orderedCustom = lib.map applyTo custom;
      knownIds = map (m: m.id) (orderedBase ++ orderedCustom);
      effectiveExtras = lib.filter (m: ! (lib.elem m.id knownIds)) extraModels;
      orderedRaw = orderedBase ++ orderedCustom ++ (lib.map applyTo effectiveExtras);
      orderedIds = lib.unique (map (m: m.id) orderedRaw);
      idMap = lib.listToAttrs (map (m: { name = m.id; value = m; }) orderedRaw);

      # dsh-llm-pi-ai 枚举（lib/index.js 实测）
      supportedThinkingFormats = [
        "openai" "deepseek" "openrouter" "together"
        "zai" "qwen" "chat-template" "qwen-chat-template"
      ];
      maxTokensFields = [ "max_tokens" "max_completion_tokens" ];

      toDshModel = m:
        let
          compat = lib.filterAttrs (n: _: lib.elem n allowedCompat) (m.compat or {});
          efforts = lib.filterAttrs (l: _: lib.elem l thinkingLevels) (m.thinkingLevelMap or {});
          hasThinking = (lib.filter (l: l != "off" && builtins.hasAttr l efforts) thinkingLevels) != [];
        in
        assert m ? contextWindow && m ? maxTokens;
        assert lib.all (mod: lib.elem mod [ "text" "image" ]) (m.input or []);
        assert ! (compat ? thinkingFormat)
          || lib.elem compat.thinkingFormat supportedThinkingFormats;
        assert ! (compat ? maxTokensField)
          || lib.elem compat.maxTokensField maxTokensFields;
        # dsh：wire 值必须非空字符串，仅 off 允许留空（null）
        assert (lib.filterAttrs (l: v:
          !(v == null || (builtins.isString v && (l == "off" || v != "")))) efforts) == {};
        {
          id = m.id;
          name = m.name or m.id;
          contextWindow = m.contextWindow;
          maxTokens = m.maxTokens;
          input = m.input or [ "text" ];
        }
        // lib.optionalAttrs hasThinking { reasoningEfforts = efforts; }
        // lib.optionalAttrs (compat != {}) { compat = compat; };

    in
    assert (lib.length orderedIds) > 0;
    lib.map (id: toDshModel idMap.${id}) orderedIds;

  # 嵌入 providerPatch 的 models: 块。本 nixpkgs 的 toYAML 是 toJSON 别名
  # （JSON flow 风格，会污染人工可读的 patch 文件）；模型条目结构固定
  # （扁平字段 + 最多二层 map），手写 block 风格 emitter，风格与既有文件
  # 一致（models: 在列 8，条目在列 10）。注意：indented string 的插值行
  # 只有首行继承源缩进，后续行原样落到列 0，所以整块必须预缩进到绝对列位，
  # 插值行写在与 writeText 去缩进边界对齐的位置（源缩进 4 = 去缩进后 0）。
  yamlIndent10 = s: "          " + lib.replaceStrings [ "\n" ] [ "\n          " ] s;
  yamlScalar = v:
    if builtins.isInt v then builtins.toString v
    else if v == true then "true"
    else if v == false then "false"
    else if builtins.match "^[A-Za-z0-9._]+( [A-Za-z0-9._]+)*$" (builtins.toString v) != null
    then builtins.toString v
    else "\"${builtins.replaceStrings [ "\"" ] [ "\\\"" ] (builtins.toString v)}\"";
  yamlModel = m:
    let
      effortLevels = lib.filter (l: builtins.hasAttr l (m.reasoningEfforts or {})) thinkingLevels;
      compatKeys = lib.filter (k: builtins.hasAttr k (m.compat or {})) allowedCompat;
    in
    [
      "- id: ${yamlScalar m.id}"
      "  name: ${yamlScalar m.name}"
      "  contextWindow: ${toString m.contextWindow}"
      "  maxTokens: ${toString m.maxTokens}"
      "  input: [${lib.concatMapStringsSep ", " yamlScalar m.input}]"
    ]
    ++ lib.optional (m ? reasoningEfforts) "  reasoningEfforts:"
    ++ (lib.map (l: "    ${l}: ${yamlScalar m.reasoningEfforts.${l}}") effortLevels)
    ++ lib.optional (m ? compat) "  compat:"
    ++ (lib.map (k: "    ${k}: ${yamlScalar m.compat.${k}}") compatKeys);
  runinfraModelsYaml = yamlIndent10 (lib.concatStringsSep "\n" (lib.concatMap yamlModel runinfraModels));

  # ---- nvidia-nim adapter ------------------------------------------------
  # 模型清单来源：data/nvidia-nim-models.json —— 从 pi-nvidia-nim@1.1.23（rev
  # dca7731，JSON 内 upstream 字段）转录。与 runinfra 不同，该扩展没有静态
  # models.json（运行时 fetch /v1/models live discovery），故 dsh 侧取策展的
  # FEATURED_MODELS 快照；pi 运行时发现的 100+ 模型不在 dsh（dsh 注册表是静态
  # 清单，无 live discovery）。thinking 经 dsh chatTemplateKwargs 的 $var 表达
  # （pi-ai resolveChatTemplateKwargValue 同一求值路径，语义已对照 store 内
  # pi-ai dist/api/openai-completions.js 实测）。同步：升级 pi-nvidia-nim npm
  # 版本 → 按新 rev 重新生成 JSON（映射规则见 JSON 内 upstream.note）→ rebuild。
  nimModelsRaw = (lib.importJSON ./data/nvidia-nim-models.json).models;
  # name 已在生成 JSON 时按扩展 makeDisplayName 规则预计算（本 nixpkgs 无
  # lib.splitOn，不在 nix 侧重复实现字符串拆分）。
  # flow-map 递归渲染（chatTemplateKwargs 内嵌一层 $var 对象）
  # 注意：lambda 体内的字符串不能在另一个 ${...} 插值上下文内再开 ${}
  #（Nix 字符串插值是词法嵌套禁止的），故逐键构造先提到独立字符串
  nimYamlVal = v:
    if v == null then "null"
    else if v == true then "true"
    else if v == false then "false"
    else if builtins.isAttrs v
    then let
      pairs = lib.map (k: "${k}: ${nimYamlVal (lib.getAttr k v)}") (builtins.attrNames v);
    in "{${lib.concatStringsSep ", " pairs}}"
    else yamlScalar v;
  nimModelYaml = m:
    let
      # 扩展 buildModelEntry 的默认 compat：NIM 对 developer role +
      # chat_template_kwargs 组合会 500，故全量关闭；max_tokens 字段名更安全。
      # supportsReasoningEffort 默认 false（effort 走 chatTemplateKwargs $var），
      # kimi 例外（JSON 内覆盖为 true，走顶层 reasoning_effort）。
      compat = { supportsDeveloperRole = false; supportsReasoningEffort = false; maxTokensField = "max_tokens"; }
        // (m.compat or {});
      effortPairs = lib.map (l: "${l}: ${nimYamlVal (lib.getAttr l m.reasoningEfforts)}")
        (lib.filter (l: builtins.hasAttr l (m.reasoningEfforts or {})) thinkingLevels);
    in
    [
      "- id: ${yamlScalar m.id}"
      "  name: ${yamlScalar m.name}"
      "  contextWindow: ${toString m.contextWindow}"
      "  maxTokens: ${toString m.maxTokens}"
      "  input: [${lib.concatMapStringsSep ", " yamlScalar m.input}]"
    ]
    ++ lib.optional (m ? reasoningEfforts) "  reasoningEfforts: {${lib.concatStringsSep ", " effortPairs}}"
    ++ [ "  compat: ${nimYamlVal compat}" ];
  nimModelsYaml = yamlIndent10 (lib.concatStringsSep "\n" (lib.concatMap nimModelYaml nimModelsRaw));

  # 静态 patch 层：cordis.patch.yml 只被 dsh 只读加载（从不写回），
  # 所以可以安全地由 nix 托管（软链接到 store）。provider 模型路由放这里。
  providerPatch = pkgs.writeText "dsh-cordis.patch.yml" ''
    - id: llm-pi-ai
      config:
        providers:
          deepseek:
            apiKeyEnv: DEEPSEEK_API_KEY
          # openai 路由 = 企业 relay（全目录分组，123 模型；key/baseURL
          # 走 clan vars openai-relay 渲染进 dsh.env）。声明 models 会替换内置
          # 38 模型 catalog（catalog 默认指 api.openai.com，该 key 在那 401），
          # 故显式列出实测可用的模型：deepseek-v4 系 3 个 + relay 实际服务的
          # gpt-5.x 5 个（catalog 内，ctx/max/input 从内置 catalog 继承）。
          # relay 角色白名单无 developer（实测 400）→ 路由级 supportsDeveloperRole。
          # relay 共 123 模型（claude/gemini/kimi/qwen/glm...），需要再补。
          openai:
            apiKeyEnv: OPENAI_API_KEY
            displayName: OpenAI Relay
            api: openai-completions
            baseURL: !!js process.env.OPENAI_BASE_URL
            compat:
              supportsDeveloperRole: false
            models:
              - id: deepseek-v4-flash
                name: DeepSeek V4 Flash
                contextWindow: 1000000
                maxTokens: 384000
                input: [text]
                reasoningEfforts:
                  minimal: null
                  low: null
                  medium: null
                  high: high
                  max: max
                compat:
                  thinkingFormat: deepseek
                  maxTokensField: max_tokens
                  requiresReasoningContentOnAssistantMessages: true
              - id: deepseek-v4-flash-vision-exp
                name: DeepSeek V4 Flash Vision Exp
                contextWindow: 1000000
                maxTokens: 384000
                input: [text, image]
                reasoningEfforts:
                  minimal: null
                  low: null
                  medium: null
                  high: high
                  max: max
                compat:
                  thinkingFormat: deepseek
                  maxTokensField: max_tokens
                  requiresReasoningContentOnAssistantMessages: true
              - id: deepseek-v4-pro
                name: DeepSeek V4 Pro
                contextWindow: 1000000
                maxTokens: 384000
                input: [text]
                reasoningEfforts:
                  minimal: null
                  low: null
                  medium: null
                  high: high
                  max: max
                compat:
                  thinkingFormat: deepseek
                  maxTokensField: max_tokens
                  requiresReasoningContentOnAssistantMessages: true
              - id: gpt-5.4
              - id: gpt-5.4-mini
              - id: gpt-5.5
              - id: gpt-5.6-sol
              - id: gpt-5.6-terra
          # opencode-go 是 pi-ai 内置 catalog 路由（OpenCode Zen Go 网关，
          # 含 deepseek-v4-pro/flash、glm-5.2、kimi-k3、qwen3.7 等模型），
          # 认证环境变量 OPENCODE_API_KEY 与 jojo home 注入一致。
          opencode-go:
            apiKeyEnv: OPENCODE_API_KEY
          # openrouter 是 pi-ai 内置 catalog 路由（https://openrouter.ai/api/v1，
          # openai-completions），catalog 内置 276 个模型，无需手工声明 models。
          openrouter:
            apiKeyEnv: OPENROUTER_API_KEY
          # ox-alpha（stealth/ox-alpha）已转正为智谱 GLM-5.3-Flash，走 zai-coding-cn
          # 端点，此 openrouter 独立路由已移除（2026-08-26）。
          # runinfra：openai-completions 网关。模型清单不再手抄——由上方
          # runinfraModels adapter 从 pi 扩展（pi-runinfra-provider-src，与 pi
          # 侧同一 rev）生成，单一数据源；同步方式见 adapter 注释。
          # key 来自 pi auth.json 的 runinfra 条目（已迁入 sops secrets/env.yaml）。
          # 注意 schema：api/baseURL 在 provider 层（models 条目不接受这些字段）；
          # cost 不在 dsh patch schema，adapter 已丢弃。
          runinfra:
            apiKeyEnv: RUNINFRA_GATEWAY_KEY
            displayName: RunInfra
            api: openai-completions
            baseURL: https://api.runinfra.ai/v1
            models:
    ${runinfraModelsYaml}
          # nvidia-nim：NVIDIA NIM 网关（build.nvidia.com）。模型清单转录自
          # pi-nvidia-nim@1.1.23 的 FEATURED_MODELS 策展清单（见上方 adapter
          # 与 data/nvidia-nim-models.json）；key 由 clan vars
          # （nvidia-nim-api-key）管理，渲染进 dsh.env 的 NVIDIA_NIM_API_KEY。
          nvidia-nim:
            apiKeyEnv: NVIDIA_NIM_API_KEY
            displayName: NVIDIA NIM
            api: openai-completions
            baseURL: https://integrate.api.nvidia.com/v1
            models:
    ${nimModelsYaml}
          zai-coding-cn:
            apiKeyEnv: ZAI_CODING_CN_API_KEY
            models:
              # ox-alpha 正式版（Z.ai blog：1M context，仅文本）。maxTokens 参考
              # glm-5.3 取 131072，文档未单列 flash 的 max output。
              - id: glm-5.3-flash
                name: GLM-5.3 Flash
                contextWindow: 1000000
                maxTokens: 131072
                reasoningEfforts:
                  low: high
                  medium: high
                  high: high
                  max: max
                compat:
                  thinkingFormat: zai
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
        (covers models missing from the bundled pi-ai catalog, e.g. glm-5.3-flash).
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
