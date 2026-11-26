/**
 * web-search-route: 按**发起搜索的模型路由**在两条 DeepSeek 服务端搜索通道之间分派。
 *
 * ## 要解决的问题
 *
 * 上游 `dsh-web-search-deepseek` 一个实例只服务一个端点 + 一份凭据。而这里的会话模型
 * 在两条路由间切换（`deepseek-official` 走官方 `DEEPSEEK_API_KEY`，`deepseek-relay`
 * 走企业网关的 `RELAY_API_KEY`），希望**搜索跟着当前模型走**：
 *
 *   - `deepseek-official` / `deepseek-account` → 官方 Anthropic 兼容端点；
 *   - 其余路由（`deepseek-relay`、`relay`、其它第三方）→ relay 网关。
 *
 * 上游没有这个分派点：provider 选择虽然跟随路由，但 relay 侧没有可用的
 * `deepseek-search-api` 上游通道（实测 `/v1/tools/search` 报 `model_not_found`），
 * 而 `deepseek-official` 的 `baseURL` 是进程级静态值。所以只能自己注册一个 provider。
 *
 * ## 为什么复用上游的 provider 类，而不是重写 HTTP
 *
 * 一次服务端搜索 = Anthropic Messages + `web_search_20250305` server tool，再解析
 * `web_search_tool_result` 块。这部分（含凭据优先级、错误分类、取消、endpoint 诊断文案）
 * 全在 `DeepSeekSearchProvider` 里，且该类已被上游导出。这里只做**两件事**：
 *
 *   1. 按 `request.llmProvider` 选实例；
 *   2. 给两个实例各自的 options（端点、凭据引用、模型名）。
 *
 * 重写一份等于把上游的协议细节复制成第二事实源，升级即腐化。
 *
 * ## 端点从哪来
 *
 * 不在代码里硬编码任何端点（本仓库公开）：
 *   - 官方侧：`officialBaseURL` → `$DEEPSEEK_SEARCH_BASE_URL` → 上游默认值；
 *   - relay 侧：`relayBaseURLEnv` 指向的环境变量（默认 `DEEPSEEK_RELAY_BASE_URL`，
 *     已由 sops 渲染进 dsh.env，与 LLM 路由同源）。
 *
 * `baseURL` 不含 `/messages`，由 provider 追加。
 *
 * ## 凭据
 *
 * 两把 key 都经 `@deepseek-ai/dsh-llm-deepseek` 的共享 helper 解析：credentials 服务
 * 优先，缺失时回落到启动环境。relay 侧不解析 DeepSeek 账号 token（网关不认）。
 *
 * PEER 依赖：`@deepseek-ai/*` 由 installation 提供（mk-bundle 把 node_modules 链回
 * `<runtime>/node_modules`），本包零私有运行期依赖。
 */

import z from '@deepseek-ai/schemastery'
import { credentialRef } from '@deepseek-ai/dsh-credentials'
import { launchEnvironmentOf } from '@deepseek-ai/dsh-launch-environment'
import {
  deepSeekApiKeyConfigured,
  rejectDeepSeekAccountToken,
  resolveDeepSeekAccountToken,
  resolveDeepSeekApiKey,
} from '@deepseek-ai/dsh-llm-deepseek'
import { DeepSeekSearchProvider } from '@deepseek-ai/dsh-web-search-deepseek'

export const name = 'web-search-route'

/** `web` 是注册目标；没有它的 profile（TUI/headless）里本插件不激活。 */
export const inject = ['web']

/** 本 provider 在 `ctx.web` 注册表里的 id，也是 `web.searchProvider` 要 pin 的值。 */
export const ROUTE_PROVIDER_ID = 'deepseek-route'

/** 走官方端点的路由集合。其余路由一律走 relay。 */
const OFFICIAL_ROUTES = new Set(['deepseek-official', 'deepseek-account'])

/** 用账号 token（而非 API key）的路由，与上游 provider 的判据一致。 */
const ACCOUNT_ROUTE = 'deepseek-account'

/** 上游的官方辅助搜索端点，仅作兜底默认值。 */
const DEFAULT_OFFICIAL_BASE_URL = 'https://api.deepseek.com/anthropic/v1'

/** 官方侧端点可覆盖的环境变量，与上游 `dsh-web-search-deepseek` 同名同义。 */
const OFFICIAL_BASE_URL_ENV = 'DEEPSEEK_SEARCH_BASE_URL'

/** 官方侧模型的 Anthropic 格式默认名。 */
const DEFAULT_OFFICIAL_MODEL = 'deepseek-v4-flash'

/** relay 侧模型的默认名（网关 catalog 里的 id）。 */
const DEFAULT_RELAY_MODEL = 'deepseek-flash'

export const Config = z.object({
  /** 官方侧端点；空 = `$DEEPSEEK_SEARCH_BASE_URL`，再空 = 上游默认值。 */
  officialBaseURL: z.string().default(''),
  /** 官方侧凭据引用。 */
  officialApiKeyEnv: z.string().default('DEEPSEEK_API_KEY'),
  /** 官方侧 Anthropic 模型名。 */
  officialModel: z.string().default(DEFAULT_OFFICIAL_MODEL),
  /** 承载 relay 端点的环境变量名（值形如 `https://gateway/v1`）。 */
  relayBaseURLEnv: z.string().default('DEEPSEEK_RELAY_BASE_URL'),
  /** relay 侧凭据引用。 */
  relayApiKeyEnv: z.string().default('RELAY_API_KEY'),
  /** relay 侧 Anthropic 模型名。 */
  relayModel: z.string().default(DEFAULT_RELAY_MODEL),
  /** 单次辅助搜索的生成 token 上限，透传给上游 provider。 */
  maxTokens: z.number().step(1).min(1).default(4096),
  /** 单次搜索允许的 `web_search` 服务端工具次数，透传给上游 provider。 */
  maxUses: z.number().step(1).min(1).default(5),
})

/** 把上游 provider 的固定字段集中在一处，两条侧只差端点/凭据/模型。 */
const API_VERSION = '2023-06-01'

/**
 * 当前 initiator 会话的模型路由。上游用它判断账号 token；这里用它判断分派方向。
 * 无会话（脚本直调）时返回 undefined。
 * @param ctx - 插件上下文。
 * @returns 路由 id，或 undefined。
 */
function currentRoute(ctx) {
  return ctx.get('agents')?.currentInitiator()?.session.requestContext()?.provider
}

/**
 * 把一条 secret-free 的辅助搜索请求记进会话事件日志。上游的 `web/deepseek-search-llm-request`
 * 事件类型已由 `dsh-web-search-deepseek` 声明，两条侧共用同一事件名，靠 `endpoint` 区分。
 * @param ctx - 插件上下文。
 * @param request - 上游 provider 交给 `recordRequest` 的请求体。
 */
function recordSearchRequest(ctx, request) {
  ctx.get('agents')?.currentInitiator()?.session.append('web/deepseek-search-llm-request', request)
}

/**
 * 官方侧端点：显式配置 > 环境变量 > 上游默认值。
 * @param ctx - 插件上下文（读启动环境）。
 * @param configured - `officialBaseURL` 配置值，空串表示未配置。
 * @returns 不含 `/messages` 的端点基址。
 */
function officialBaseURL(ctx, configured) {
  if (configured.length > 0) return configured
  return launchEnvironmentOf(ctx).get(OFFICIAL_BASE_URL_ENV)?.value ?? DEFAULT_OFFICIAL_BASE_URL
}

/**
 * relay 侧端点：只来自环境变量。缺失时返回空串，让 `available()` 报不可用而不是
 * 把请求发到一个相对路径。
 * @param ctx - 插件上下文。
 * @param envName - 承载端点的环境变量名。
 * @returns 不含 `/messages` 的端点基址，可能为空。
 */
function relayBaseURL(ctx, envName) {
  return launchEnvironmentOf(ctx).get(envName)?.value ?? ''
}

/**
 * 官方侧的可用性检查：account 路由先看账号 token（与上游同序），再看 API key。
 * 只读配置，不发网络请求；读取失败按不可用处理（搜索本身也会在读失败处失败）。
 * @param ctx - 插件上下文。
 * @param apiKeyEnv - 官方侧凭据引用。
 * @param route - 本次搜索所属的模型路由。
 * @param configuredBaseURL - `officialBaseURL` 配置值，空串表示未配置。
 * @returns 是否具备发请求所需的凭据。
 */
async function officialReady(ctx, apiKeyEnv, route, configuredBaseURL) {
  if (route === ACCOUNT_ROUTE) {
    const account = ctx.get('deepseekAccount')
    if (account !== undefined) {
      let token
      try {
        token = await account.resolveToken(`${officialBaseURL(ctx, configuredBaseURL)}/messages`)
      } catch {
        return false
      }
      if (token !== undefined && token.length > 0) return true
    }
  }
  try {
    return await deepSeekApiKeyConfigured(ctx, apiKeyEnv)
  } catch {
    return false
  }
}

/**
 * relay 侧的可用性检查：只看 API key 是否存在。
 * @param ctx - 插件上下文。
 * @param apiKeyEnv - relay 侧凭据引用。
 * @returns 是否具备发请求所需的凭据。
 */
async function relayReady(ctx, apiKeyEnv) {
  try {
    return await deepSeekApiKeyConfigured(ctx, apiKeyEnv)
  } catch {
    return false
  }
}

/**
 * 注册按路由分派的搜索 provider。
 * @param ctx - 插件上下文，需已挂载 `web` 服务。
 * @param config - 已应用默认值的配置段。
 */
export function apply(ctx, config) {
  const officialRef = credentialRef(config.officialApiKeyEnv)
  const relayRef = credentialRef(config.relayApiKeyEnv)

  const official = new DeepSeekSearchProvider(() => ({
    resolveAccountToken: async (endpoint) => {
      if (currentRoute(ctx) !== ACCOUNT_ROUTE) return undefined
      return await resolveDeepSeekAccountToken(ctx, endpoint)
    },
    rejectAccountToken: token => rejectDeepSeekAccountToken(ctx, token),
    resolveApiKey: () => resolveDeepSeekApiKey(ctx, officialRef),
    apiKeyEnv: officialRef,
    baseURL: officialBaseURL(ctx, config.officialBaseURL),
    model: config.officialModel,
    apiVersion: API_VERSION,
    maxTokens: config.maxTokens,
    maxUses: config.maxUses,
    recordRequest: request => recordSearchRequest(ctx, request),
  }))

  const relay = new DeepSeekSearchProvider(() => ({
    // relay 网关不认 DeepSeek 账号 token：只走它自己的 API key。
    resolveApiKey: () => resolveDeepSeekApiKey(ctx, relayRef),
    apiKeyEnv: relayRef,
    baseURL: relayBaseURL(ctx, config.relayBaseURLEnv),
    model: config.relayModel,
    apiVersion: API_VERSION,
    maxTokens: config.maxTokens,
    maxUses: config.maxUses,
    recordRequest: request => recordSearchRequest(ctx, request),
  }))

  /**
   * 分派：没有模型路由（脚本直调）时按 relay 处理——本仓库的会话模型默认就在 relay 上。
   * @param route - 模型路由 id。
   * @returns 该路由对应的上游 provider 实例。
   */
  const sideFor = route => (route !== undefined && OFFICIAL_ROUTES.has(route) ? official : relay)

  ctx.web.registerSearchProvider({
    id: ROUTE_PROVIDER_ID,
    title: 'DeepSeek (route-aware)',
    description: {
      en: 'DeepSeek server-side search on the endpoint of the model route: the official endpoint for official/account routes, the relay gateway for every other route. No per-search charge; each search spends model tokens.',
      zh: '按当前模型路由选择 DeepSeek 服务端搜索的端点：官方/账号路由走官方，其余走 relay 网关。搜索不按次收费，每次搜索消耗模型 token。',
    },
    available: () => official.available() || relay.available(),
    ready: async (llmProvider) => {
      const route = llmProvider ?? currentRoute(ctx)
      return OFFICIAL_ROUTES.has(route)
        ? await officialReady(ctx, officialRef, route, config.officialBaseURL)
        : await relayReady(ctx, relayRef)
    },
    search: async (request, signal) => await sideFor(request.llmProvider ?? currentRoute(ctx)).search(request, signal),
  })
}
