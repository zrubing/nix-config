/**
 * 回归测试：假 ctx + 打桩 fetch 驱动 apply()。不起 dsh、不读也不写 $DSH_HOME、
 * 不发任何真实网络请求。
 *
 * 覆盖点：
 *   1. 注册 id 与 inject；
 *   2. 分派：官方路由 → 官方端点，其余/缺失路由 → relay 端点；
 *   3. 端点后缀：baseURL 后追加 `/messages`；
 *   4. ready：凭据缺失时对应侧报不可用。
 *
 * 运行：`node test.mjs`（需在产物目录，node_modules 由 mk-bundle 链回 installation）。
 */

import assert from 'node:assert/strict'
import { apply, Config, ROUTE_PROVIDER_ID } from './index.js'

/** 构造一个只实现本插件所需接缝的假 ctx。 */
function fakeContext(envValues) {
  const registered = { search: undefined }
  const snapshot = {
    get: name => (envValues[name] === undefined ? undefined : { value: envValues[name] }),
  }
  const ctx = {
    get: name => (name === 'launchEnvironment' ? snapshot : undefined),
    web: {
      registerSearchProvider: provider => {
        registered.search = provider
      },
    },
  }
  return { ctx, registered }
}

/** 打桩 fetch，记录请求 URL，返回一个含 web_search_tool_result 的最小响应。 */
function stubFetch() {
  const calls = []
  const original = globalThis.fetch
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), body: JSON.parse(init.body) })
    return new Response(JSON.stringify({
      content: [{
        type: 'web_search_tool_result',
        tool_use_id: 'call_0',
        content: [{ type: 'web_search_result', url: 'https://example.test/a', title: 'A' }],
      }],
    }), { status: 200, headers: { 'content-type': 'application/json' } })
  }
  return { calls, restore: () => { globalThis.fetch = original } }
}

const ENV = {
  DEEPSEEK_RELAY_BASE_URL: 'https://relay.test/v1',
  RELAY_API_KEY: 'relay-key-placeholder',
  DEEPSEEK_API_KEY: 'official-key-placeholder',
}

const { ctx, registered } = fakeContext(ENV)
apply(ctx, Config({}))
const provider = registered.search
assert.ok(provider, 'apply() must register a search provider')
assert.equal(provider.id, ROUTE_PROVIDER_ID)

const http = stubFetch()
try {
  // 1. 官方路由 → 官方端点
  const official = await provider.search({ query: 'q1', llmProvider: 'deepseek-official' })
  assert.equal(http.calls.length, 1)
  assert.equal(http.calls[0].url, 'https://api.deepseek.com/anthropic/v1/messages')
  assert.equal(http.calls[0].body.model, 'deepseek-v4-flash')
  assert.equal(official.sources.length, 1, 'official side must parse the result blocks')

  // 2. relay 路由 → relay 端点 + relay 模型
  const relay = await provider.search({ query: 'q2', llmProvider: 'deepseek-relay' })
  assert.equal(http.calls.length, 2)
  assert.equal(http.calls[1].url, `${ENV.DEEPSEEK_RELAY_BASE_URL}/messages`)
  assert.equal(http.calls[1].body.model, 'deepseek-flash')
  assert.equal(relay.sources.length, 1, 'relay side must parse the result blocks')

  // 3. 无路由（脚本直调）→ relay
  await provider.search({ query: 'q3' })
  assert.equal(http.calls[2].url, `${ENV.DEEPSEEK_RELAY_BASE_URL}/messages`)

  // 4. ready：两把 key 都在 → 两侧都就绪
  assert.equal(await provider.ready('deepseek-official'), true)
  assert.equal(await provider.ready('deepseek-relay'), true)
} finally {
  http.restore()
}

// 5. 凭据缺失时对应侧报不可用（另一侧不受影响）
{
  const { ctx: bareCtx, registered: bare } = fakeContext({
    DEEPSEEK_RELAY_BASE_URL: ENV.DEEPSEEK_RELAY_BASE_URL,
  })
  apply(bareCtx, Config({}))
  assert.equal(await bare.search.ready('deepseek-relay'), false, 'missing relay key must report not ready')
  assert.equal(await bare.search.ready('deepseek-official'), false, 'missing official key must report not ready')
}

console.log('web-search-route: all assertions passed')
