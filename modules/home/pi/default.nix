{
  config,
  lib,
  pkgs,
  inputs,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.pi;
  flakeLock = builtins.fromJSON (builtins.readFile ../../../flake.lock);
  guardrailsRev = flakeLock.nodes."pi-guardrails-src".locked.rev;
  guardrailsPackage = "git:github.com/zrubing/pi-guardrails#${guardrailsRev}";
  # RunInfra provider 不再由上游 pi-runinfra-provider 包提供（2026-09-30 退役）：
  # 它内嵌 models.json 快照且合并时永不删 id，网关改名后 pi 会一直展示旧 id，
  # 与 dsh 漂移。现由本仓库的本地扩展读 dsh autosync 发布的 catalog。

  # ── 凭据投递：pi 自己没有注入机制，必须包一层 wrapper ──────────────────
  #
  # pi 只从**进程环境**读 OPENCODE_API_KEY / DEEPSEEK_RELAY_API_KEY 等
  # （catalog 里 "opencode-go": "OPENCODE_API_KEY"，实测 `pi auth check`），
  # 而 ~/.config/default.env 只有交互式 bash 的 .bashrc 会 source：
  #   bash -ic 'pi auth check --provider opencode-go' → ready
  #   bash -lc 'pi auth check --provider opencode-go' → not_ready
  # 也就是 ssh 命令、GUI 启动器、niri bind 直接 exec、dsh 的 agent 子进程
  # （敏感名被 scrub）里起的 pi 全都没有 key。dsh 不受影响是因为它自己有
  # wrapper / EnvironmentFile 去 source dsh.env，与这里同一个模式。
  piPackage = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;

  # 唯一职责：source 一次 default.env 再 exec 原二进制。参数、退出码、
  # `pi update self` 全部原样透传。
  piWithEnv = pkgs.writeShellScriptBin "pi" ''
    if [ -r "$HOME/.config/default.env" ]; then
      set -a
      . "$HOME/.config/default.env"
      set +a
    fi
    # pi-cache-optimizer：先只开“统计 + prompt_cache_key 兜底 + 代理 compat 告警”。
    # 它的 prompt 改写（压缩 skill 列表、剔除 session-overview 抖动）默认开启，
    # 会改变送进模型的 system prompt——与“测缓存命中”是两个变量，先不叠在一起。
    # 要开改写就删掉这一行。
    export PI_CACHE_OPTIMIZER_NO_PROMPT_REWRITE=1
    exec ${piPackage}/bin/pi "$@"
  '';

  # 共享的 relay 路由事实（modules/home/llm-routes/routes.nix），与 dsh 侧同源。
  # baseUrl 不在共享声明里：pi 只对 apiKey / headers 做 "$VAR" env 插值，
  # baseUrl 原样直读（源码实测 dist/core/provider-composer.js 的 modelFromJson），
  # 故仍由 age 密文提供——合并时按 provider 整体以 overlay 为准，只补回密文的
  # baseUrl（规则见 modules/home/agenix）。
  llmRoutes = import ../llm-routes/routes.nix { inherit lib; };
  relayRoute = llmRoutes.relay;

  # 共享 schema（dsh 规范式）→ pi models.json 的 provider 条目
  relayProvider = {
    name = relayRoute.displayName;
    api = relayRoute.api;
    apiKey = "$" + relayRoute.apiKeyEnv;
    compat = relayRoute.compat;
    models = lib.map (m: {
      inherit (m) id name contextWindow maxTokens;
      input = m.input or [ "text" ];
      # 缺级补 null = 该级不支持（pi 的 thinkingLevelMap 三态语义）
      thinkingLevelMap = lib.genAttrs llmRoutes.thinkingLevels (
        l: if builtins.hasAttr l (m.reasoningEfforts or { }) then m.reasoningEfforts.${l} else null
      );
      reasoning = (lib.filter (l: l != "off" && builtins.hasAttr l (m.reasoningEfforts or { })) llmRoutes.thinkingLevels) != [ ];
      cost = m.cost or {
        input = 0;
        output = 0;
        cacheRead = 0;
        cacheWrite = 0;
      };
      # pi 原生前缀缓存保温（0.86+）的资格声明：只有声明了「best-effort 寿命」的
      # 模型才进入 warming 候选，没这条 = 永不续命。pi 只在「避免的 miss 成本 ≥ $0.05」
      # 时才真续——按本路由 cacheRead 0.007 / input 0.22 算，前缀要 ~235k token 以上才会
      # 触发，短会话完全不参与（不花钱）。DeepSeek 官方未公布 TTL（只说长期不用的条目
      # 会自动清空），取保守端 1 小时：真实 TTL 更长只是少续几次，不会更贵（一次续命
      # ≈ 0.007/M × 前缀）。pi 专有概念，dsh 侧无对应字段，故留在 pi 渲染器里（同 cost）。
      promptCache = {
        short = 3600;
      };
    } // lib.optionalAttrs (m ? compat) { inherit (m) compat; }) relayRoute.models;
  };

  # ── 缓存优化：只用「不注册 session_before_compact」的方案 ──
  # 历史：pi-deepseek-cache（P1 遥测 / P2 前缀守卫 / P3 缓存友好压缩 / P4 保温否决）
  # 曾以本地 patched 副本加载，因为 P3 与 pi-blackhole 抢 session_before_compact。
  # 2026-10-27 换成两层组合，都不碰 compaction：
  #   1. 保温本身用 pi 1.4.0 原生：settings.json 的 cacheWarming + 模型条目的 promptCache
  #      （见上方 relayProvider）。注意它的硬门槛：CACHE_WARMING_MINIMUM_EXPECTED_SAVINGS
  #      是硬编码 0.05 美元、不可配置，按本路由定价反推需要前缀 ≥ ~243k token，
  #      且 streaming 模式只在单次 run 内有效（agent settle 就停）——交互式基本不触发，
  #      属于“零成本占位”，靠它不能救命中率；
  #   2. 遥测与代理兼容用 pi-cache-optimizer（见下文 packages）：它注册的 hook 集合
  #      与 blackhole 零重叠（blackhole 只有 agent_start/turn_end/session_compact/
  #      session_before_compact/agent_end），且 cache_warming_decision 只在零价模型上
  #      答 warm，不会抢原生决策。
  # 仍然排除的：任何注册 session_before_compact 的缓存扩展（pi-deepseek-cache、
  # pi-dc-distill 等）—— 最后注册者覆盖，与 blackhole 的 OM 折叠直接互斥。
  # 旧扩展的数据目录 ~/.pi/agent/extensions/deepseek-cache/（stats.json / history.json /
  # summary-cache.json）已无消费者，保留为历史数据，需要时手动删。

  # ── MCP servers：统一源（modules/home/mcp-servers/servers.nix）的 pi 视图 ──
  # pi 0.99 起内置 mcp 扩展直接支持 MCP（/mcp、codemode、OAuth 等），不再需要
  # pi-mcp-adapter 包：两者都注册 /mcp 命令，装了插件内置 mcp 会拒绝加载
  # （实测启动警告：extension registers command /mcp, built-in mcp was not loaded）。
  mcpServers = import ../mcp-servers/servers.nix {
    inherit lib pkgs namespace;
    homeDirectory = config.home.homeDirectory;
    # 内置 mcp 只对 env / headers 做 ${VAR} 插值，url 必须是合法 http(s)
    # 字面量 → { sops = "…"; var = "…"; } 值在此换成 sops 占位符，
    # 随下方 mcp.json 模板在激活期替换为明文。
    piValue = { sops, ... }: config.sops.placeholder.${sops};
  };
  piMcpJson = builtins.toJSON { mcpServers = mcpServers.piServers; };

  # pi-blackhole 三个 memory worker 共用的模型（deepseek-v4.1-flash 便宜快，适合后台任务）
  # id 取自 pi 侧 opencode-go catalog（catalog 与 discovery 缓存里只有
  # deepseek-v4-pro / deepseek-v4.1-flash 两个 deepseek 模型；原 deepseek-v4-flash
  # 已不在清单内，会在 modelRegistry.find 时报 not found）
  # contextWindow 显式声明 1M，OM pipeline 会在调用前检查输入是否放得下
  # 注意：provider 与 id 是分开的字段，id 只写模型名（不带 provider 前缀），
  # 否则 modelRegistry.find(provider, id) 匹配不到，会报 "provider/provider/id not found"
  blackholeWorkerModel = {
    provider = "opencode-go";
    id = "deepseek-v4.1-flash";
    thinking = "low";
    contextWindow = 1000000;
  };
  piSettings = builtins.toJSON {
    packages = [
      # MCP 由内置 mcp 扩展提供（/mcp、codemode），不装 pi-mcp-adapter。
      "npm:@howaboua/pi-codex-conversion@2.2.7"
      "npm:pi-blackhole@0.4.3"
      "npm:context-mode@1.0.169"
      "npm:@aliou/pi-processes@0.9.5"
      "npm:pi-deepseek-search@1.0.15"
      # 缓存优化：不注册 session_before_compact（与 pi-blackhole 的 hook 集合零重叠），
      # 提供 footer 缓存统计分片、OpenAI 兼容 prompt_cache_key 兜底、代理 compat 告警。
      # 注意它自带 cache_warming_decision 处理器——只在“模型价格全为 0”时答 warm，
      # 其余返 undefined 让位给 pi 原生决策，故不会与我们的 promptCache 冲突。
      "npm:pi-cache-optimizer@2.10.4"
      # 缓存保温本身仍走 pi 原生 cacheWarming + 模型 promptCache（不装 compaction 类缓存扩展）。
      # runinfra 不在此声明：见上文本地扩展。
      # NVIDIA NIM 网关 provider（integrate.api.nvidia.com/v1，100+ 模型，
      # 运行时 live discovery）。dsh 侧对应 data/nvidia-nim-models.json 静态
      # 快照（见 modules/home/dsh），升级时两边一起动。
      "npm:pi-nvidia-nim@1.1.23"
    ];
    # pi 原生前缀缓存保温：streaming = 活跃会话期内、缓存即将过期前重发一次；
    # idle 才管会话之间。上游默认就是 streaming，这里写死防止默认值漂移。
    cacheWarming = "streaming";
    # —— settings.json 不支持 `providers` 键（pi 源码 Settings 接口无此字段），
    #    modelOverrides 已移到下方 piModelsOverlayJson，经 agenix merge 进 models.json
  };
  # models.json overlay：非机密模型配置，与 agenix secrets(agents/pi/models.json) 深合并生成最终 models.json
  #（merge 逻辑见 modules/home/agenix/default.nix）。settings.json 不能放 providers，只能放这里。
  # runinfra 由本地扩展运行时注册，模型清单与 per-model 容量都来自 dsh 发布的
  # catalog，这里不再叠加 modelOverrides（那份覆盖值只在 dsh 侧生效，随 catalog 传出）。
  piModelsOverlayJson = builtins.toJSON {
    providers = {
      # relay：字段全部来自 routes.nix；只有 baseUrl 仍需 age 密文提供。
      "${relayRoute.name}" = relayProvider;
    };
  };
  # pi-blackhole 独立配置文件（不读 settings.json 的 observational-memory 块）
  # 阈值按 1M 上下文窗口调优：compactAfterTokens = 60% 窗口（官方建议 60-70%），
  # 其余按 high-context preset（~200k+）档位配置
  blackholeConfig = builtins.toJSON {
    observerModel = blackholeWorkerModel;
    reflectorModel = blackholeWorkerModel;
    dropperModel = blackholeWorkerModel;
    observeAfterTokens = 20000;
    reflectAfterTokens = 40000;
    compactAfterTokens = 600000;
    observerChunkMaxTokens = 80000;
    observationsPoolMaxTokens = 40000;
    reflectorInputMaxTokens = 160000;
    dropperInputMaxTokens = 160000;
    dropperPressureThreshold = 0.70;
  };
in
{

  options.${namespace}.modules.pi = {
    enable = lib.mkEnableOption "pi agent configuration (settings, skills, extensions)";

    superpowers.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable superpowers skills (brainstorming, etc.) in pi agent.";
    };
  };

  config = lib.mkIf cfg.enable {
    # 覆盖 modules/home/packages 装的 pkgs-nix-ai.pi 的 bin/pi。同一个 profile
    # 里两个包都提供 bin/pi，靠 hiPrio 让这层 wrapper 胜出（home-manager 的
    # buildEnv 按 meta.priority 解冲突，同优先级会报 collision）。
    home.packages = [ (lib.hiPrio piWithEnv) ];

    home.file.".pi/agent/settings.json" = {
      text = piSettings;
      force = true;
    };
    home.file.".config/pi/models-overlay.json" = {
      text = piModelsOverlayJson;
    };
    home.file.".pi/agent/pi-blackhole/pi-blackhole-config.json" = {
      text = blackholeConfig;
      force = true;
    };
    # RunInfra provider：本地薄扩展，只读 dsh autosync 发布的 catalog
    # （~/.cache/llm/runinfra-models.json）。同步逻辑唯一实现在
    # modules/home/dsh/plugins/autosync/lib/runinfra.js，pi 侧不重复实现。
    home.file.".pi/agent/extensions/runinfra/index.ts".source =
      ./extensions/runinfra/index.ts;
    # skills 声明已移到 modules/home/skills（共享 skill 模块）：同一份清单同时投放到
    # ~/.agents/skills（pi / DSH / Codex）与 ~/.claude/skills（Claude Code）。
    # git 权威源仍是 .pi/skill-sources/*；此处不再单独声明。
    home.file.".pi/agent/extensions/guardrails.json".source = ../../../.pi/extensions/guardrails.json;

    # pi 的全局指令（~/.pi/agent/AGENTS.md）：pi 每个目录只取一个 context
    # file（源码 loadContextFileFromDir 依次试 AGENTS.override.md → AGENTS.md
    # → AGENTS.MD → CLAUDE.md → CLAUDE.MD，首个命中即返回），没有 include
    # 机制，故用 sops 模板合成——本模块同目录的 AGENTS.md（pi 专属偏好，
    # 明文入库）+ 共享加密文档（sops.secrets."agents/AGENTS.md" = 通用协作
    # 偏好，渲染在 ~/.agents/AGENTS.md）。改内容 = 改仓库后 switch；
    # 原先手写的 ~/.pi/agent/AGENTS.md 已备份为
    # ~/.pi/agent/AGENTS.md.pre-nix-backup（含其末尾的明文数据库口令段，
    # 未随本文件入库）。
    sops.templates."pi-agents-md" = {
      path = "/home/${config.snowfallorg.user.name}/.pi/agent/AGENTS.md";
      content = builtins.readFile ./AGENTS.md + "\n\n" + config.sops.placeholder."agents/AGENTS.md";
    };

    # ~/.pi/agent/mcp.json：内置 mcp 读该文件（项目级 .pi/mcp.json 另算）。
    # 整个文件走 sops 渲染的理由：agent-docs 的 url 内置 mcp 不做 ${VAR} 插值，
    # 必须落成字面量，而仓库不放明文地址（见 mcp-servers/servers.nix 头部）。
    # 副作用：pi mcp add / /mcp 面板对该文件的改动会在下次 switch 被覆盖——
    # 增删 server 一律改 servers.nix 的 pi 视图。
    sops.templates."pi-mcp-json" = {
      path = "/home/${config.snowfallorg.user.name}/.pi/agent/mcp.json";
      mode = "0600";
      content = piMcpJson;
    };

    # nvidia-nim 的 key 现在只走 env（default.env 的 NVIDIA_NIM_API_KEY）。
    # 原先这里用 activation 把 key 合并进 ~/.pi/agent/auth.json，与 agenix 打架：
    # 该文件是 place 出来的软链（modules/home/agenix 的
    # "agents/pi/auth.json"），`mv` 会把软链顶成普通文件，下次激活 agenix 又
    # 换回软链 —— 两边互相擦，条目时有时无（2026-10-27 实测就只剩 runinfra 一条）。
    # env 路径由 pi 的 wrapper source default.env 保证，启动方式无关。

    # home.activation.configurePiGuardrailsFork = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    #   settings_file="$HOME/.pi/agent/settings.json"
    #   ${pkgs.coreutils}/bin/mkdir -p "$HOME/.pi/agent"
    #
    #   if [ ! -f "$settings_file" ]; then
    #     cat > "$settings_file" <<'EOF'
    #   {
    #     "packages": []
    #   }
    #   EOF
    #   fi
    #
    #   ${pkgs.jq}/bin/jq \
    #     --arg forkPkg '${guardrailsPackage}' \
    #     '
    #     .packages = (
    #       ((.packages // [])
    #         | map(select(. != "npm:@aliou/pi-guardrails" and (. | startswith("git:github.com/zrubing/pi-guardrails") | not))))
    #       + [$forkPkg]
    #       | unique
    #     )
    #     ' "$settings_file" > "$settings_file.tmp"
    #
    #   ${pkgs.coreutils}/bin/mv "$settings_file.tmp" "$settings_file"
    # '';
  };

}
