# LLM 路由的共享事实（单一来源）。
#
# 范围刻意收窄到「两个消费方真的都要读」的东西：
#   relay / deepseekRelay —— dsh 与 pi 都声明这两个 provider（dsh 走 cordis
#                   patch，pi 走 models-overlay.json），字段必须一致，否则同一
#                   网关两侧的 key / 模型集合 / 能力元数据会各自漂移。两条路由
#                   共用同一个 baseURL（值见 deepseekRelay.baseURLEnv）与同一把
#                   key（clan vars relay/api-key），只是模型集合不同。
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
  deepseekRelayModelMeta = {
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
  # 三条 openai-completions 共用：网关是 OpenAI 兼容层，thinking 走
  # reasoning_effort；max_tokens 是它的字段名（探针见下）。
  openaiCompat = {
    thinkingFormat = "openai";
    supportsReasoningEffort = true;
    maxTokensField = "max_tokens";
  };

  # 多厂商 relay：与 deepseek-relay 同一个网关，另一把按模型授权的令牌
  # （2026-11-11 用 deepseek-relay 的 key 打 /v1/models 只列 deepseek-flash；
  # 换成这把后同一端点返回 claude-* / gemini-* / gpt-* 二十多条 —— 网关按令牌
  # 收窄模型集合）。
  #
  # 容量/档位/定价取自 models.dev（2026-11-11 抓取），不靠猜：
  #   gemini-4-carbon    google/vertex slice：1M ctx；output 两个 slice 不一致
  #                      （32768 / 65536），探针实测 max_tokens 65536 与 131072
  #                      都 200（网关不校验模型上限），取 Vertex 值 65536
  #   claude-opus-5-5    anthropic slice：1M ctx / 128k output；effort low..max
  #   claude-fable-5-2   同上；定价 8/40（2026-11-09 发布）
  #
  # 探针实测（2026-11-11，本 key）：
  #   - 三个模型纯文本均 200；max_tokens 65536/131072 均被接受（网关不拒绝超过
  #     模型上限的值，所以上限一律取 models.dev 的数字）
  #   - gemini-4-carbon：不传 reasoning_effort 也会思考（thinking 默认开），
  #     reasoning_effort low/medium/high 均生效（reasoning_tokens > 0）
  #   - claude-opus-5-5 / claude-fable-5-2：reasoning_effort high/max/xhigh 均
  #     200（网关接受该键），但 usage 里 reasoning_tokens 恒为 0，实际思考深度
  #     无法从响应侧验证
  #   - 1x1 PNG 附件 200（三个模型都试过）
  #   - developer 角色 200；保守起见仍按 supportsDeveloperRole = false 走 system
  relayModelMeta = {
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
      compat = openaiCompat;
      # pi 专有（dsh patch schema 无 cost 字段）：官方 API 定价（USD / 1M token），
      # 企业网关是否按此计费以账单为准。
      cost = {
        input = 2;
        output = 10;
        cacheRead = 0.1;
        cacheWrite = 0;
      };
    };
    "claude-opus-5-5" = {
      name = "Claude Opus 5.5";
      contextWindow = 1000000;
      maxTokens = 128000;
      input = [ "text" "image" ];
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        high = "high";
        xhigh = "xhigh";
        max = "max";
      };
      compat = openaiCompat;
      cost = {
        input = 4;
        output = 20;
        cacheRead = 0.2;
        cacheWrite = 5;
      };
    };
    "claude-fable-5-2" = {
      name = "Claude Fable 5.2";
      contextWindow = 1000000;
      maxTokens = 128000;
      input = [ "text" "image" ];
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        high = "high";
        xhigh = "xhigh";
        max = "max";
      };
      compat = openaiCompat;
      cost = {
        input = 8;
        output = 40;
        cacheRead = 0.2;
        cacheWrite = 10;
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
  inherit thinkingLevels compatKeys deepseekRelayModelMeta opencodeFreeModelMeta modelLock;

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
  # 模型集合 = models.lock.json 的 deepseek-relay 段（手工 curated，只留
  # deepseek-flash）。key 于 2026-11-17 与 relay 路由统一到 clan vars
  # relay/api-key：原 deepseek-relay/api-key 被网关判为无效令牌（/v1/models
  # 401「无效的令牌」），统一后的 key 对 deepseek-flash 实测 200。要扩集合改锁
  # 文件并在下方补元数据，两侧同时跟随。
  deepseekRelay = {
    name = "deepseek-relay";
    displayName = "DeepSeek Relay";
    api = "openai-completions";
    # 凭据引用而非明文：值与 relay 路由同源（clan vars relay/api-key），由 sops
    # 渲染进 dsh.env（dsh-web 读）与 default.env（终端 agent，pi 读）。pi 的
    # models.json 对 apiKey 做 "$VAR" 插值，故 pi 侧写引用即可，明文不入 age 密文。
    apiKeyEnv = "RELAY_API_KEY";
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
        (deepseekRelayModelMeta.${id} or (
          throw "llm-routes: models.lock.json 里有 deepseek-relay/${id}，但 routes.nix 没有它的元数据（容量/档位不能猜，请手工补一条）"
        ))
        // {
          inherit id;
        }
      ) modelLock."deepseek-relay"
    );
  };

  # relay 路由（网关的完整令牌集合）与 deepseekRelay 共用同一把 key，两家路由
  # 的差别只剩模型清单：
  #
  # 非 catalog 路由：pi-ai 没有这些 id 的内置条目，能力元数据只能在这里声明。
  # 模型集合是**字面清单**而不是锁文件：本轮只要这三个 id（网关里还有
  # gemini-4-argon、gemini-3.x、gpt-* 等）。要跟随网关清单时再迁到
  # models.lock.json，并补一条 autosync 描述符（见 pkgs/dsh-local 的
  # deepseek-relay 行）—— 那一步会给每条新 id 触发「缺元数据」的求值报错。
  relay = {
    name = "relay";
    displayName = "Relay";
    api = "openai-completions";
    # 网关唯一 key（clan vars relay/api-key）：deepseekRelay 路由引用同一个 env。
    apiKeyEnv = "RELAY_API_KEY";
    # 与 deepseek-relay 同一个端点事实：值来自 clan vars openai-relay/base-url，
    # 渲染进 dsh.env 的 DEEPSEEK_RELAY_BASE_URL（env 名保留历史拼写，见 dsh 模块）。
    baseURLEnv = "DEEPSEEK_RELAY_BASE_URL";
    compat = {
      supportsDeveloperRole = false;
    };
    # 路由级默认思考档：dsh 只有这一个默认（做不到按模型分档），取 opus 的 xhigh。
    # gemini 只提供到 high，dsh 的 describableReasoningLevel 对不支持的档位返回
    # undefined（回落 provider 默认），不会报错。pi 侧的 per-model 默认在
    # settings.json 的 modelThinkingLevels（见 modules/home/pi）。
    reasoning = "xhigh";
    models = validate "relay" [
      (relayModelMeta."gemini-4-carbon" // {
        id = "gemini-4-carbon";
      })
      (relayModelMeta."claude-opus-5-5" // {
        id = "claude-opus-5-5";
      })
      (relayModelMeta."claude-fable-5-2" // {
        id = "claude-fable-5-2";
      })
    ];
  };

}
