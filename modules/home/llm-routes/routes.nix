# LLM 路由的共享事实（单一来源）。
#
# 范围刻意收窄到「两个消费方真的都要读」的东西：
#   relay        —— dsh 与 pi 都声明这个 provider（dsh 走 cordis patch，
#                   pi 走 models-overlay.json），字段必须一致，否则同一网关
#                   两侧的 key / 模型集合 / 能力元数据会各自漂移。
#   runinfraModelOverrides —— 两侧都要给 deepseek-v4-flash 同一个输出上限。
#                   runinfra 的 provider 由 pi-runinfra-provider 扩展在运行时
#                   注册，模型清单只有 dsh 需要（dsh 的 adapter 从扩展源码树
#                   派生），故清单留在 dsh 模块，不在这里。
#
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
in
{
  inherit thinkingLevels compatKeys;

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
    models = validate "deepseek-relay" [
      {
        id = "deepseek-flash";
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
      }
    ];
  };

  # runinfra 唯一需要共享的事实：两侧给同一个模型同一个输出上限。
  # 扩展 patch.json 给 deepseek-v4-flash 的 maxTokens 是 32768，而网关
  # /v1/models 报 max_output_tokens=1048576、pi 侧既有 overlay 钉在 65536。
  # dsh 的 adapter 把本值叠加到派生清单上，pi 直接放进 overlay。
  runinfraModelOverrides = {
    deepseek-v4-flash = {
      maxTokens = 65536;
    };
  };
}
