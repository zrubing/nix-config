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
  # dsh 二进制来源：默认用 llm-agents 打包的 npm 版（@deepseek-ai/dsh 0.1.1-rc.2）；
  # useDshSource=true 改用从 deepseek-harness 源码构建的本仓库包（packages/dsh-source，
  # 即 Moraxyc 式 kernel 方案产出的 dsh-kernel，追 main/0.1.2-alpha.1，npm 尚无此版）。
  # llm-agents 更新后把 useDshSource 改回 false 即切回。
  dshPackage =
    if cfg.useDshSource
    then import ../../../packages/dsh-source { inherit lib pkgs inputs; }
    else inputs.llm-agents.packages.${system}.dsh;
  # 本地 plugin（tool-processes / compact-blackhole）导入 @deepseek-ai/* 的 node_modules 根。
  # llm-agents npm 版与源码 kernel 版布局不同，按后端切换。
  dshNodeModules =
    if cfg.useDshSource
    then "${dshPackage}/lib/deepseek-harness/node_modules"
    else "${dshPackage}/lib/node_modules/@deepseek-ai/dsh/node_modules";
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

  # OpenBao LDAP agent 密码注入（shell-env 注册表）：dsh 的子进程 env 构建会
  # 擦除名字匹配 KEY|PASSWORD|SECRET|TOKEN 的宿主变量（scrubbedParentEnv，
  # 刻意安全设计），但 shell-env 注册表是官方受信通道（DSH_* 命名空间，每次
  # shell 调用重建、经 executor 在 scrub 之后注入）。本插件照 dsh-web-app 的
  # 官方范例注册 contributor：resolver 从宿主进程 env 读
  # OPENBAO_LDAP_AGENT_PASSWORD（dsh-web-start 已 source dsh.env），注入为
  # DSH_OPENBAO_LDAP_AGENT_PASSWORD。agent 配合 OPENBAO_LDAP_AGENT_USERNAME
  # （非敏感名，不受 scrub）+ BAO_ADDR 即可 bao login 零交互取动态 MySQL 凭证。
  # 装载 = activation 以 file: 依赖装入 web profile + 本文件 providerPatch 的
  # insert 行；同 braces-sanitize 双件套。
  openbaoShellEnvPlugin = pkgs.runCommand "dsh-openbao-shell-env" { } ''
    mkdir -p $out
    cp ${./plugins/openbao-shell-env/package.json} $out/package.json
    cp ${./plugins/openbao-shell-env/index.js} $out/index.js
  '';

  # composer 模型座位替换（可搜索 + Provider 前缀）。client-ui 插件：host 半区
  # 空 apply 占位，浏览器半区 lib/client.js 是手写的 __ModuleLoader__.load 单文件
  # 产物（vendor seed 模块 react / jsx-runtime / ui-primitives 之外零依赖）。
  # 数据面复用官方 ui-model-selection 的 ModelDirectoryResolver（ctx.modelDirectories），
  # 不重复挂载 resolver、不动 /model 命令；官方座位组件保持挂载，被本插件在同
  # `conversation.input.model` 单座位上的后注册者遮蔽（single slot shadowing：
  # 后注册优先级数值更低、胜出）。装载 = activation 以 file: 依赖装入 web
  # profile（configureDshModelSelectPlus）+ 本文件 providerPatch 的 insert 行；
  # 与 braces-sanitize 同款双件套。headless 未装包时该 insert 行仅告警跳过。
  modelSelectPlusPlugin = pkgs.runCommand "dsh-model-select-plus" { } ''
    mkdir -p $out/lib
    cp ${./plugins/model-select-plus/package.json} $out/package.json
    cp ${./plugins/model-select-plus/lib/index.js} $out/lib/index.js
    cp ${./plugins/model-select-plus/lib/client.js} $out/lib/client.js
  '';

  # 自动发现 opencode-go 实时模型（见 plugins/opencode-autosync/lib/index.js 注释）。
  # host-only 插件，零 @deepseek-ai/* 导入（不走 node_modules shim）：服务全部经
  # ctx.get 惰性解析，网络发现复用 ctx.llm.discoverModels（provider 故意省略以绕过
  # dsh-llm-pi-ai 对 catalog provider 的短路，见插件源码 Why）。构建产物只含
  # package.json + lib/index.js，activation 以 file: 装入 web profile；loader 行
  # 在 providerPatch 的 opencode-autosync insert 条目。同 braces-sanitize /
  # model-select-plus 双件套。headless 未装包时该行仅告警跳过。
  opencodeAutosyncPlugin = pkgs.runCommand "dsh-opencode-autosync" { } ''
    mkdir -p $out/lib
    cp ${./plugins/opencode-autosync/package.json} $out/package.json
    cp ${./plugins/opencode-autosync/lib/index.js} $out/lib/index.js
  '';

  # pi-processes（aliou）的 agent 侧移植。pi extension（@earendil-works/* 契约 +
  # TUI 面板）无法被 dsh 加载——dsh 唯一的 pi 关联包 dsh-llm-pi-ai 只是 LLM API
  # 适配层，不是 extension 宿主。这里移植对 agent 真正有用的半区：start_process
  # 工具后台起进程不阻塞对话，进程句柄注册进 host 的 ctx.jobs（完成通知 /
  # job_output 增量读 / job_kill 终止 / web UI jobs 面板全部复用），收集工具由
  # preset 里的 tool-jobs 行提供。preset 行用相对说明符 ./tool-processes.js 加载
  # （dsh-agent-presets：preset 自带文件随 preset 走），但 preset 目录向上没有
  # node_modules，裸 @deepseek-ai/* 导入会失败——故把插件源码与一个 node_modules
  # shim（符号链接回 dsh 包自身的 node_modules——这个包的依赖嵌套在
  # @deepseek-ai/dsh/node_modules，不在 lib/node_modules 顶层）构建进同一 store
  # 路径，dsh 升级（flake.lock 变更）时随 input 重建。
  toolProcessesPlugin = pkgs.runCommand "dsh-tool-processes" { } ''
    mkdir -p $out
    cp ${./agent-presets/my-minimal/tool-processes.js} $out/tool-processes.js
    ln -s ${dshNodeModules} $out/node_modules
  '';

  # pi-blackhole (k0valik @0.4.3) 适配器 —— 独立 dsh 插件包（modules/home/dsh/plugins/dsh-blackhole，
  # 不是 Snowfall 的 packages/：它需要 dsh 模块独有的 dshNodeModules，不能进 flake packages 输出）。
  # 采用「导入上游核心」的适配器模式：nix 让包的 scripts/build.sh 用 esbuild 把 pi-blackhole 的纯 TS
  # 核心（src/core/summarize.ts 的 compile 管线 + recall 检索，仅依赖 node 内建 + 一个 pi-tui
  # wrapTextWithAnsi 占位）打成 ESM bundle，dsh 侧只保留薄适配器：to-pi.js（dsh Message -> pi
  # Message）、compaction 引擎（覆写 summarize()）、recall 工具、OM worker、/blackhole* 命令。
  # 上游更新 = flake.lock 换 rev + rebuild，不再手工 re-port。阈值、/compact、<compacted-summary>、
  # tool-result pruner 沿用 dsh。
  blackholePlugin = import ./plugins/dsh-blackhole/build.nix { inherit lib pkgs inputs dshNodeModules; };

  # ── my-minimal preset 组合：上游 shipped `minimal` + 本地增量行 ────────────
  # dsh 的 preset composition（@deepseek-ai/dsh-agent-presets + 底层
  # cordis-plugin-include）没有 extends/继承/合并机制：`PresetTree`/`Include`
  # 只读一个顶层插件行数组，行的 `name` 被解析成一个模块，`cordis:group` 只是
  # 嵌套、`patches` 是宿主级（cordis.patch.yml）而非 preset 级。所以「my-minimal
  # = shipped minimal + 我的新增」无法在 agent.cordis.yml 里表达，只能在 Nix
  # 求值期把两边文本拼成一份合法 composition。
  #
  # 基础部分（persona / persistent-shell / filesystem）直接读 flake input
  # deepseek-harness-src 的源码树 `packages/preset/agent-presets/presets/minimal/`，
  # 与 useDshSource=true（源码构建）共享同一 rev（flake.lock）：上游更新 minimal
  # → nix flake update deepseek-harness-src + rebuild → 基础行自动跟随，不再手抄
  # 快照。增量行（web_search / start_process 后台进程 / pi-blackhole /
  # 确定性压缩）是你本地维护的 extras.cordis.yml，真正属于你的部分。
  # 若将来切回 useDshSource=false（llm-agents npm 版），此路径需按 npm 版布局调整。
  #
  # 拼接产物是合法 composition（顶层数组），由 home.file 以 text= 写入
  # ~/.dsh/.agent-presets/my-minimal/agent.cordis.yml（见下文）。
  myMinimalComposition =
    builtins.readFile (
      inputs.deepseek-harness-src
      + "/packages/preset/agent-presets/presets/minimal/agent.cordis.yml"
    )
    + "\n"
    + builtins.readFile ./agent-presets/my-minimal/extras.cordis.yml;

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
          # flash 支持图片输入（同 zai-coding-cn 的 glm-5.3-flash）；缺 image
          # 声明时 dsh 会把附件按纯文本路由处理。
          input = [ "text" "image" ];
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
          # 官方 api.deepseek.com 不在此声明：web profile 内置第一方 llm-deepseek
          # 插件已注册 deepseek-official（显示名 DeepSeek，同样读 DEEPSEEK_API_KEY，
          # 模型更全——含 vision-exp 与文件上传直传）。之前这里配置的 pi-ai catalog
          # deepseek 路由与之完全重复，导致模型选择器同时出现 DeepSeek（官方）和
          # deepseek（catalog id 兜底名）两项；已移除。dsh-web-search-deepseek
          # 也只认 deepseek-official，不受影响。
          # deepseek-relay 路由 = 企业 relay（与官方 DeepSeek 分开；该 key
          # key/baseURL 走 clan vars openai-relay 渲染进 dsh.env 的
          # DEEPSEEK_RELAY_* 独立 env，不影响原 OPENAI_API_KEY）。非 catalog 路由，models 必须全量
          # 显式列出（实测可用 3 个，元数据对齐 opencode-go catalog 同家族条目）。
          # relay 角色白名单无 developer（实测 400）→ 路由级 supportsDeveloperRole。
          # relay /models 共 123 个，后续要加其他模型在此补。
          deepseek-relay:
            apiKeyEnv: DEEPSEEK_RELAY_API_KEY
            displayName: DeepSeek Relay
            api: openai-completions
            baseURL: !!js process.env.DEEPSEEK_RELAY_BASE_URL
            compat:
              supportsDeveloperRole: false
            models:
              - id: deepseek-v4-flash
                name: DeepSeek V4 Flash
                contextWindow: 1000000
                maxTokens: 384000
                input: [text]
                reasoningEfforts:
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
                  high: high
                  max: max
                compat:
                  thinkingFormat: deepseek
                  maxTokensField: max_tokens
                  requiresReasoningContentOnAssistantMessages: true
          # opencode-go 是 pi-ai 内置 catalog 路由（OpenCode Zen Go 网关，
          # 含 deepseek-v4-pro/flash、glm-5.2、kimi-k3、qwen3.7 等模型），
          # 认证环境变量 OPENCODE_API_KEY 与 jojo home 注入一致。
          # 2026-08-29 实测：网关 /go/v1/chat/completions 对 catalog 判定为
          # anthropic-messages 的 minimax-m3 / qwen3.7-max 也 200（统一 OpenAI
          # 兼容端）。catalog 是混合 api（anthropic/openai-completions/
          # openai-responses），sharedCatalogApi 返回 undefined，而 dsh schema 只认
          # 路由级 api（request.api ?? base?.api；models 条目不接受 api/baseURL），
          # 故补 catalog 未描述的模型（如 qwen3.8-flash 等，由 dsh-opencode-autosync
          # 自动发现）必须给路由声明 api + baseURL。这会顺带让 catalog 里少数
          # anthropic 模型改走 openai-completions（已验证可用）。
          opencode-go:
            apiKeyEnv: OPENCODE_API_KEY
            api: openai-completions
            baseURL: https://opencode.ai/zen/go/v1
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
              # ox-alpha 正式版（Z.ai blog：1M context）。flash 支持图片输入，
              # 不声明 input 时按纯文本模型处理（附件被降级/拒绝）→ 显式列 image。
              # maxTokens 参考 glm-5.3 取 131072，文档未单列 flash 的 max output。
              - id: glm-5.3-flash
                name: GLM-5.3 Flash
                contextWindow: 1000000
                maxTokens: 131072
                input: [text, image]
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
          # 内置 catalog 路由 openai（gpt 全家族，api=openai-responses）重定向到企业
          # relay 端点。base URL 与 deepseek-relay 同源：clan vars openai-relay/base-url
          # 渲染进 dsh.env 的 DEEPSEEK_RELAY_BASE_URL（同一网关，单一事实来源，换值仍
          # clan vars set zen14 openai-relay/base-url）；认证沿用路由默认 OPENAI_API_KEY。
          # 模型清单保持 catalog 原样，仅以 modelOverrides 钉住 gpt-5.6-sol 的
          # contextWindow（272000 = 上游 pricing tiers 分档边界，防 catalog 漂移）。
          # 注意：modelOverrides 只允许出现在未声明 models 列表的 catalog 路由上，
          # 两者同配会被 dsh 拒载。
          openai:
            baseURL: !!js process.env.DEEPSEEK_RELAY_BASE_URL
            modelOverrides:
              gpt-5.6-sol:
                contextWindow: 272000

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

    # GitHub 远程 MCP server（官方托管 https://api.githubcopilot.com/mcp/，
    # streamable-http，认证 Authorization: Bearer <PAT>）。PAT 由 clan vars 加密
    # 管理（clan/zen14.nix github-mcp-token），渲染进 dsh.env 的 GITHUB_MCP_TOKEN，
    # 此处运行时求值，patch 文件不含明文。远程托管免 docker，dsh-web 服务里最稳；
    # 工具面由服务端默认 toolset 决定（与 pi 侧 docker 版 GITHUB_DYNAMIC_TOOLSETS=1
    # 不同）。
    - insert:
        - id: mcp-github
          name: '@deepseek-ai/dsh-mcp-client'
          config:
            serverName: github
            transport: streamable-http
            url: https://api.githubcopilot.com/mcp/
            headers:
              Authorization: !!js '"Bearer " + process.env.GITHUB_MCP_TOKEN'

    # 工具描述花括号清洗（见上方 bracesSanitizePlugin 注释）。waterfall listener
    # 在 next() 之后改写权威 assembly，注册顺序无关；headless 未装包时本条目
    # 加载仅告警跳过。
    - insert:
        - id: mcp-braces-sanitize
          name: dsh-braces-sanitize
          config: {}

    # composer 模型座位替换（见上方 modelSelectPlusPlugin 注释）。行必须在官方
    # ui-model-selection（dsh-web-app bundle 层）之后插入：浏览器端单座位按注册
    # 顺序选举，后注册的本插件胜出。headless 未装包时仅告警跳过。
    - insert:
        - id: ui-model-select-plus
          name: '@local/dsh-model-select-plus'
          config: {}

    # OpenBao LDAP agent 密码注入（见上方 openbaoShellEnvPlugin 注释）：
    # shell-env 注册表 contributor，把 DSH_OPENBAO_LDAP_AGENT_PASSWORD 注入
    # 每次模型 shell 调用（宿主敏感 env 被 scrub，这是官方受信通道）。
    # headless 未装包时仅告警跳过。
    - insert:
        - id: openbao-shell-env
          name: dsh-openbao-shell-env
          config: {}

    # 自动发现 opencode-go 实时模型（见上方 opencodeAutosyncPlugin 注释）。
    # host-only 插件：启动 + 每 intervalMs 拉 opencode.ai Go 档清单，add-only
    # 并入 opencode-go 路由的 models（不删已配置条目）。config 可选覆盖：
    # route / baseURL / api / apiKeyEnv / intervalMs。headless 未装包时仅告警跳过。
    - insert:
        - id: opencode-autosync
          name: dsh-opencode-autosync
          config:
            route: opencode-go
            baseURL: https://opencode.ai/zen/go/v1
            api: openai-completions
            apiKeyEnv: OPENCODE_API_KEY
            intervalMs: 43200000

  '';

  # 竞态修复：dsh 的 baseURL/密钥依赖 sops 渲染的 envFile（~/.config/dsh.env，symlink 指向
  # sops-nix 渲染产物）。sops 模板渲染与 systemd user 服务启动之间没有排序保证，服务可能在
  # env 未就绪时先跑，而 EnvironmentFile 是 unit 启动时一次性读取（缺失只告警、不阻塞，
  # 也不会在 ExecStartPre 重读），于是 process.env 取不到 baseURL → llm-pi-ai 插件树加载失败
  # → 服务崩溃（Restart=on-failure 5s 后重启；停机窗口里浏览器执行 command → "Failed to
  # fetch"，即 command.execute.failed 的 toast）。这里改为在真正 exec dsh 的同一进程里先等
  # env 就绪再 source 进来：exec 让 dsh 取代该 bash（PID 不变，Type=simple 语义保持）。
  dshWebStart = pkgs.writeShellScript "dsh-web-start" ''
    # 防御性清理：第三方插件（曾用的 dsh-web-startup-auth 等）的 pnpm 传递依赖会把
    # @deepseek-ai/dsh-host-webserver@0.1.1-rc.2 等旧版实体目录装进 web profile 的
    # node_modules，遮蔽 kernel 的 0.1.2 版本 → webserver handler 抛异常 → GET / 400
    # （页面打不开）。每次启动前幂等删除，让解析回落到 kernel store；
    # dsh-mcp-client 是显式安装的插件，保留。
    for stale in dsh-host-webserver dsh-cmdline cosmokit schemastery; do
      rm -rf "$HOME/.dsh/profiles/web/node_modules/@deepseek-ai/$stale"
    done

    declare -r env_file=${lib.escapeShellArg cfg.envFile}
    ready=0
    i=0
    while [ "$i" -lt 120 ]; do
      if [ -s "$env_file" ] && grep -qE '^DEEPSEEK_RELAY_BASE_URL=.+' "$env_file" 2>/dev/null; then
        ready=1
        break
      fi
      sleep 0.5
      i=$((i + 1))
    done
    if [ "$ready" -ne 1 ]; then
      echo "dsh-web: env file $env_file not ready (missing/empty DEEPSEEK_RELAY_BASE_URL) after ~60s; aborting start" >&2
      exit 1
    fi
    set -a
    . "$env_file"
    set +a
    exec ${lib.getExe dshPackage} web --host ${cfg.web.host} --port ${toString cfg.web.port}${lib.concatMapStrings (h: " --trusted-host ${h}") cfg.web.trustedHosts}
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

    # systemd user service 环境极简，必须显式注入；shell 里 source 的 default.env 不会带进来。
    # 注意：不能用 Environment = [ "KEY=${config.sops.placeholder...}" ] —— placeholder 是
    # 求值期的占位符字符串，写入单元后不会被解密。必须走 sops.templates 生成 env 文件，
    # 再由 EnvironmentFile 读入（激活时 sops-nix 把 placeholder 替换为真实值）。
    envFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "EnvironmentFile for the dsh web service (sops template output).";
    };

    # 用深源码构建的 dsh（packages/dsh-src，追 deepseek-harness main）替代
    # llm-agents 打包的 npm 版。默认 false（用 llm-agents 稳定版）；体验最新版
    # 时置 true。llm-agents 更新后改回 false 即回退。
    useDshSource = mkOption {
      type = types.bool;
      default = false;
      description = "Build dsh from the deepseek-harness source tree instead of the llm-agents npm package.";
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

      # Agent presets：用户侧 preset 目录（$DSH_HOME/.agent-presets，trust=user，
      # dsh-agent-presets 的 includeUserRoot 默认扫描）。组合文件 dsh 只读——
      # PresetTree.write() 是 no-op（preset 是输入、不是持久化目标），所以可以像
      # 上面的 cordis.patch.yml 一样由 nix 静态托管；preset.yml 只是 picker 的
      # 展示文案（name/description/order），id = 目录名。生效方式：rebuild 后
      # 新建会话即挂新组合（standing mount 按 composition 文件 stamp 换代，
      # 运行中的旧会话保持原代），无需重启 dsh-web。
      # force：目录最初为手工创建，需要接管既有普通文件。
      # agent.cordis.yml 是求值产物：上游 shipped `minimal` + 本地增量行（见上方
      # myMinimalComposition）。用 text= 而非 source=，因为内容在 Nix 求值期拼好，
      # 没有对应的仓库文件；上游更新随 deepseek-harness-src 自动跟随。
      home.file.".dsh/.agent-presets/my-minimal/agent.cordis.yml" = {
        text = myMinimalComposition;
        force = true;
      };
      home.file.".dsh/.agent-presets/my-minimal/preset.yml" = {
        source = ./agent-presets/my-minimal/preset.yml;
        force = true;
      };
      # OpenBao 用法指令（用户全局 AGENTS.md）：dsh-agent-instructions 插件
      # （extras.cordis.yml 的 agent-instructions 行）把 $DSH_HOME/AGENTS.md
      # 作为每次请求的基线指令。内容见源文件（bao 登录 / 动态 MySQL 凭证 /
      # DSH_OPENBAO_LDAP_AGENT_PASSWORD 变量来源说明）。
      home.file.".dsh/AGENTS.md" = {
        source = ./agent-presets/my-minimal/AGENTS.md;
        force = true;
      };
      # start_process 插件源码在 preset 目录内（随 preset 的相对说明符加载），
      # 实体是上方 toolProcessesPlugin 的 store 产物。
      home.file.".dsh/.agent-presets/my-minimal/tool-processes.js" = {
        source = "${toolProcessesPlugin}/tool-processes.js";
        force = true;
      };
      # pi-blackhole 适配器（modules/home/dsh/plugins/dsh-blackhole 的 store 产物：package.json + lib/
      # + esbuild 打包的 pi 核心 + node_modules shim）。preset 通过相对说明符
      # ./dsh-blackhole/lib/compaction.js（压缩 isolate）与 ./dsh-blackhole/lib/index.js
      # （agent scope）挂载。
      home.file.".dsh/.agent-presets/my-minimal/dsh-blackhole" = {
        source = "${blackholePlugin}";
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
          # envFile 非空时用 dshWebStart 包装（先等 sops 渲染的 env 就绪再 exec dsh），
          # 否则直接启动（无 env 依赖）。理由见 dshWebStart 注释。
          ExecStart = if (cfg.envFile != null) then dshWebStart else
            "${lib.getExe dshPackage} web --host ${cfg.web.host} --port ${toString cfg.web.port}"
            + (lib.concatMapStrings (h: " --trusted-host ${h}") cfg.web.trustedHosts);
          Environment = [
            "PATH=/run/current-system/sw/bin:/etc/profiles/per-user/%u/bin:%h/.local/bin"
          ];
          Restart = "on-failure";
          RestartSec = 5;
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

      # OpenBao LDAP agent 密码注入（见上方 openbaoShellEnvPlugin 注释）：同
      # braces-sanitize 的 file: + store-hash 幂等安装；loader 行在
      # cordis.patch.yml 的 openbao-shell-env insert 条目。装完重启 dsh-web 生效。
      home.activation.configureDshOpenbaoShellEnv = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="file://${openbaoShellEnvPlugin}"
        if ! grep -qF "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            systemctl --user try-restart dsh-web.service 2>/dev/null || true
          else
            echo "WARN: dsh-openbao-shell-env 安装失败（离线？），下次重建重试"
          fi
        fi
      '';

      # 可搜索模型选择器（见上方 modelSelectPlusPlugin 注释）：同 braces-sanitize
      # 的 file: + store-hash 幂等安装；loader 行在 cordis.patch.yml 的
      # ui-model-select-plus insert 条目。装完重启 dsh-web 生效。
      home.activation.configureDshModelSelectPlus = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="file://${modelSelectPlusPlugin}"
        if ! grep -qF "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            systemctl --user try-restart dsh-web.service 2>/dev/null || true
          else
            echo "WARN: dsh-model-select-plus 安装失败（离线？），下次重建重试"
          fi
        fi
      '';

      # 自动发现 opencode-go 模型（见上方 opencodeAutosyncPlugin 注释）：同
      # model-select-plus 的 file: + store-hash 幂等安装；loader 行在
      # cordis.patch.yml 的 opencode-autosync insert 条目。装完重启 dsh-web 生效。
      home.activation.configureDshOpencodeAutosync = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="file://${opencodeAutosyncPlugin}"
        if ! grep -qF "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            systemctl --user try-restart dsh-web.service 2>/dev/null || true
          else
            echo "WARN: dsh-opencode-autosync 安装失败（离线？），下次重建重试"
          fi
        fi
      '';
    })
  ];
}
