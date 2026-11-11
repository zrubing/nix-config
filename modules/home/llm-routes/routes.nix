# LLM 路由的共享事实（单一来源）。
#
# 范围刻意收窄到「两个消费方真的都要读」的东西：
#   relay / geminiCarbonRelay —— dsh 与 pi 都声明这两个 provider（dsh 走 cordis
#                   patch，pi 走 models-overlay.json），字段必须一致，否则同一
#                   网关两侧的 key / 模型集合 / 能力元数据会各自漂移。两条路由
#                   共用同一个 baseURL（值见 relay.baseURLEnv），只是 key 不同。
# 本文件只产出数据（含求值期校验），不做渲染：dsh 用它已有的 YAML emitter，
# pi 用它自己的 schema 转换器。
{
  lib,
}:
let
  # pi-ai 与 dsh-llm-pi-ai 共用的思考档枚举。两侧渲染器都按它过滤。
  thinkingLevels = [ "off" "minimal" "low" "medium" "high" "xhigh" "max" ];
  # openai-completions 的 compat 键集（两侧 compat 类型的交集）。
  compatKeys = [
    "thinkingFormat"
    "supportsReasoningEffort"
    "supportsDeveloperRole"
    "supportsStore"
    "maxTokensField"
    "requiresReasoningContentOnAssistantMessages"
    "chatTemplateKwargs"
  ];
  thinkingFormats = [
    "openai"
    "deepseek"
    "openrouter"
    "together"
    "zai"
    "qwen"
    "chat-template"
    "qwen-chat-template"
  ];
  maxTokensFields = [ "max_tokens" "max_completion_tokens" ];
  modalities = [ "text" "image" ];

  # 手写声明里的错误在求值期报错，而不是渲染出一份静默错误的运行时配置。
  validateModel = route: m:
    let
      compat = m.compat or { };
      efforts = m.reasoningEfforts or { };
    in
    assert lib.assertMsg (m ? id && m.id != "") "llm-routes: ${route} 有模型缺少 id";
    assert lib.assertMsg (m ? contextWindow && m.contextWindow > 0)
      "llm-routes: ${route}/${m.id} 需要正的 contextWindow";
    assert lib.assertMsg (m ? maxTokens && m.maxTokens > 0)
      "llm-routes: ${route}/${m.id} 需要正的 maxTokens";
    assert lib.assertMsg (lib.all (mod: lib.elem mod modalities) (m.input or [ "text" ]))
      "llm-routes: ${route}/${m.id} 的 input 只能是 ${lib.concatStringsSep "/" modalities} 的子集";
    # 未知 compat 键 = 声明写错了（不是外部数据），故报错而非静默丢弃
    assert lib.assertMsg (lib.all (k: lib.elem k compatKeys) (builtins.attrNames compat))
      "llm-routes: ${route}/${m.id} 有未知的 compat 键；可用键：${lib.concatStringsSep " " compatKeys}";
    assert lib.assertMsg (!(compat ? thinkingFormat) || lib.elem compat.thinkingFormat thinkingFormats)
      "llm-routes: ${route}/${m.id} 声明了未知的 thinkingFormat";
    assert lib.assertMsg (!(compat ? maxTokensField) || lib.elem compat.maxTokensField maxTokensFields)
      "llm-routes: ${route}/${m.id} 声明了未知的 maxTokensField";
    assert lib.assertMsg (lib.all (l: lib.elem l thinkingLevels) (builtins.attrNames efforts))
      "llm-routes: ${route}/${m.id} 有未知的 reasoning 档";
    # dsh 规则：wire 值必须是非空字符串，仅 off 允许留空（null）
    assert lib.assertMsg (lib.all (l: efforts.${l} != null || l == "off") (builtins.attrNames efforts))
      "llm-routes: ${route}/${m.id} 有非 off 的 reasoning 档留空";
    m;

  validate = route: models: lib.map (validateModel route) models;

  # ── 模型 id 集合：锁文件；能力元数据：本文件 ────────────────────────────
  # 网关的 /v1/models 只公布 id，公布不了容量与档位，所以「哪些模型存在」可以
  # 生成，「每个模型多大」只能人工维护。`dsh-models-sync --update` 重写锁文件，
  # 这里按锁里的 id 取人工条目：锁里新增的 id 在元数据里缺席时**求值期报错**
  # （容量不能猜 —— 猜出来的数字在后续每一层都与真值无法区分）。
  # 锁里消失的 id 自然从清单里消失，不需要额外处理。
  modelLock = lib.importJSON ./models.lock.json;

  # 探针实测：1M 上下文、384k 输出（mt=384000 与 32768 均 200）、纯红 1x1 PNG
  # 探针 200（认图）；不传 thinking 参数也自带 reasoning_content（即 off 档实际
  # 仍会思考，故不声明 off —— 不提供关不掉的档位）。
  relayModelMeta = {
    "deepseek-flash" = {
      name = "DeepSeek V4.1 Flash";
      contextWindow = 1000000;
      maxTokens = 384000;
      input = [ "text" "image" ];
      reasoningEfforts = {
        high = "high";
        max = "max";
      };
      compat = {
        thinkingFormat = "deepseek";
        maxTokensField = "max_tokens";
        requiresReasoningContentOnAssistantMessages = true;
      };
      # pi 专有（dsh patch schema 无 cost 字段），沿用 pi 侧既有 relay 定价
      cost = {
        input = 0.22;
        output = 0.66;
        cacheRead = 0.007;
        cacheWrite = 0;
      };
      # pi 专有：前缀缓存保温的「best-effort 寿命」。只有声明了它的模型才进入
      # warming 候选；DeepSeek 未公布 TTL，取保守端 1 小时（渲染细节见
      # modules/home/pi 的 piModel）。
      promptCache = {
        short = 3600;
      };
    };
  };
  # Gemini 4 Carbon：同一 relay 网关上的另一条令牌（模型授权不同，key 也不同）。
  # 容量与档位取自 models.dev 的 google/vertex slice（2026-11-11 抓取）：
  #   limit.context 1048576；reasoning_options effort low|medium|high。
  # output 两个 slice 不一致（google 32768、google-vertex 65536）；2026-11-11 探针
  # 实测网关对 max_tokens 65536 与 131072 都返回 200（不校验模型上限），故取
  # models.dev 记的 Vertex 值 65536，不自己发明更大的数字。
  #
  # 探针实测（2026-11-11，本 key）：
  #   - 纯文本 200；不传 reasoning_effort 也会思考（thinking 默认开，回答前就花掉
  #     上百 reasoning token），故不声明 off 档。
  #   - reasoning_effort: low/medium/high 全部 200，且 completion_tokens_details
  #     .reasoning_tokens > 0 → compat.thinkingFormat = "openai" 成立，参数没有被
  #     静默丢弃。三档在这条简单题上 token 数接近，档位粒度未细究。
  #   - 1x1 PNG 附件 200（prompt_tokens 1388），故 input 声明 image。
  #   - developer 角色 200；保守起见仍按 supportsDeveloperRole = false 走 system。
  geminiCarbonModelMeta = {
    "gemini-4-carbon" = {
      name = "Gemini 4 Carbon";
      contextWindow = 1048576;
      maxTokens = 65536;
      input = [ "text" "image" ];
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        high = "high";
      };
      compat = {
        thinkingFormat = "openai";
        supportsReasoningEffort = true;
        maxTokensField = "max_tokens";
      };
      # pi 专有（dsh patch schema 无 cost 字段）：官方 API 定价（USD / 1M token），
      # 企业网关是否按此计费以账单为准。
      cost = {
        input = 2;
        output = 10;
        cacheRead = 0.1;
        cacheWrite = 0;
      };
    };
  };
  opencodeFreeModelMeta = {
    "minimax-m3.1-flash-free" = {
      name = "MiniMax M3.1 Flash Free";
      contextWindow = 1000000;
      maxTokens = 512000;
      input = [ "text" "image" ];
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        high = "high";
        xhigh = "xhigh";
        max = "max";
      };
    };
    "longcat-2.5-preview-free" = {
      name = "LongCat 2.5 Preview Free";
      contextWindow = 1000000;
      maxTokens = 131072;
      input = [ "text" "image" ];
    };
    "beam-free" = {
      name = "Beam Free";
      contextWindow = 1048576;
      maxTokens = 131072;
      input = [ "text" ];
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        high = "high";
        xhigh = "xhigh";
        max = "max";
      };
    };
  };
in
{
  inherit thinkingLevels compatKeys relayModelMeta opencodeFreeModelMeta modelLock;

  # opencode-go 的免费档：同一网关、同一把 key，`-free` 后缀单独成路由。
  # 清单同样由锁文件给 id，元数据在这里（取自 models.dev 的 opencode slice，
  # 不填默认值 —— 容量填错在后续每一层都与真值无法区分）。
  #
  # 为什么没有 `-free` 之外的模型：2026-10-20 实测，zen 档的免费模型对非
  # OpenCode 客户端返回 403 FreeTierError，Go 端对它们返回 400 Model is
  # unavailable —— 只有本表这几个在 Go 档真的能跑通。
  opencodeFree = {
    name = "opencode-free";
    displayName = "OpenCode Free";
    api = "openai-completions";
    baseURL = "https://opencode.ai/inference/go/v1";
    apiKeyEnv = "OPENCODE_API_KEY";
    models = validate "opencode-free" (
      map (
        id:
        (opencodeFreeModelMeta.${id} or (
          throw "llm-routes: models.lock.json 里有 opencode-free/${id}，但 routes.nix 没有它的元数据（容量/档位不能猜，请手工补一条）"
        ))
        // {
          inherit id;
        }
      ) modelLock."opencode-free"
    );
  };

  # 企业 relay 网关（与官方 api.deepseek.com 分开：官方由内置 llm-deepseek
  # 插件的 deepseek-official 路由服务）。
  #
  # 非 catalog 路由：pi-ai 没有它的任何内置条目，故能力元数据只能显式声明。
  # relay 角色白名单无 developer（实测 400）→ 路由级 supportsDeveloperRole。
  #
  # 模型集合以本路由所用 key 实际可访问者为限：2026-09-14 探针实测，该 key 对
  # deepseek-v4-flash / v4-pro / *-byte / vision-exp 全部 403「该令牌无权访问
  # 模型」，仅 deepseek-flash 200。换 key 或网关放开权限后改这里一处，两侧同时
  # 跟随。
  relay = {
    name = "deepseek-relay";
    displayName = "DeepSeek Relay";
    api = "openai-completions";
    # 凭据引用而非明文：值来自 clan vars deepseek-relay/api-key，由 sops 渲染进
    # dsh.env（dsh-web 读）与 default.env（终端 agent，pi 读）。pi 的 models.json
    # 对 apiKey 做 "$VAR" 插值，故 pi 侧写引用即可，明文不再入 age 密文。
    apiKeyEnv = "DEEPSEEK_RELAY_API_KEY";
    # dsh 侧 baseURL 走运行时 env（值来自 clan vars openai-relay/base-url）。
    # pi 侧仍需 age 密文提供 baseUrl：pi 只对 apiKey / headers 做 env 插值，
    # baseUrl 原样直读（源码实测 dist/core/provider-composer.js 的 modelFromJson）。
    baseURLEnv = "DEEPSEEK_RELAY_BASE_URL";
    compat = {
      supportsDeveloperRole = false;
    };
    # 路由级默认思考档：dsh 把 profile.reasoning 交给每个模型当默认值
    # （describableReasoningLevel → defaultEffort），模型选择器以此为初值。
    reasoning = "max";
    # 探针实测：1M 上下文、384k 输出（mt=384000 与 32768 均 200）、纯红 1x1 PNG
    # 探针 200（认图）；不传 thinking 参数也自带 reasoning_content（即 off 档实际
    # 仍会思考，故不声明 off —— 不提供关不掉的档位）。
    models = validate "deepseek-relay" (
      map (
        id:
        (relayModelMeta.${id} or (
          throw "llm-routes: models.lock.json 里有 deepseek-relay/${id}，但 routes.nix 没有它的元数据（容量/档位不能猜，请手工补一条）"
        ))
        // {
          inherit id;
        }
      ) modelLock."deepseek-relay"
    );
  };

  # Gemini 4 Carbon 走**同一个** relay 网关（同一个 baseURL），但用另一把按模型
  # 授权的 key：2026-11-11 用 deepseek-relay 的 key 打 /v1/models，清单只有
  # deepseek-flash；换成这把 key 后同一端点返回 claude-* / gemini-* / gpt-* 二十
  # 多条 —— 网关按令牌收窄模型集合。
  #
  # 非 catalog 路由（同 relay）：pi-ai 没有内置条目，能力元数据只能在这里声明。
  # 模型集合是**字面清单**而不是锁文件：本轮只明确要 gemini-4-carbon 一个 id
  # （网关里还有 gemini-4-argon、gemini-3.x 等）。要跟随网关清单时再迁到
  # models.lock.json，并补一条 autosync 描述符（见 pkgs/dsh-local 的
  # deepseek-relay 行）—— 那一步会给每条新 id 触发「缺元数据」的求值报错。
  geminiCarbonRelay = {
    name = "gemini-4-carbon-relay";
    displayName = "Gemini 4 Carbon Relay";
    api = "openai-completions";
    apiKeyEnv = "GEMINI_CARBON_RELAY_API_KEY";
    # 与 deepseek-relay 同一个端点事实：值来自 clan vars openai-relay/base-url，
    # 渲染进 dsh.env 的 DEEPSEEK_RELAY_BASE_URL（env 名保留历史拼写，见 dsh 模块）。
    baseURLEnv = "DEEPSEEK_RELAY_BASE_URL";
    compat = {
      supportsDeveloperRole = false;
    };
    reasoning = "high";
    models = validate "gemini-4-carbon-relay" [
      (geminiCarbonModelMeta."gemini-4-carbon" // {
        id = "gemini-4-carbon";
      })
    ];
  };

}
