# dsh-web-search-route

按**发起搜索的模型路由**在两条 DeepSeek 服务端搜索通道之间分派 `web_search`。

## 为什么需要它

上游 `dsh-web-search-deepseek` 的一个实例只服务一个端点 + 一份凭据：

- `deepseek-official`（llm-deepseek）用 `DEEPSEEK_API_KEY` 打官方端点；
- `deepseek-relay`（llm-pi-ai）用 `RELAY_API_KEY` 打企业网关。

而 `web` 服务的 provider 选择规则里，只有 `deepseek-official` / `deepseek-account`
路由会优先选 `deepseek-official`；其余路由落到 `deepseek-search-api`（客户端检索）。
后者在 relay 上不可用——实测 `POST /v1/tools/search` 返回
`503 model_not_found ... deepseek-search`，网关没有该上游通道。

所以“搜索跟着当前模型走”在上游组合里没有现成落点，只能注册一个 provider 自己分派。

## 分派规则

| 会话模型路由 | 使用的端点 | 凭据引用 |
|---|---|---|
| `deepseek-official` | `$DEEPSEEK_SEARCH_BASE_URL` or 官方默认 | `DEEPSEEK_API_KEY` |
| `deepseek-account` | 同上（优先账号 token） | 账号 token → `DEEPSEEK_API_KEY` |
| 其余（`deepseek-relay`、`relay`、第三方） | `$DEEPSEEK_RELAY_BASE_URL` | `RELAY_API_KEY` |

没有模型路由的搜索（脚本直调）按 relay 处理：本仓库默认会话模型就在 relay 上。

两条侧都复用上游 `DeepSeekSearchProvider` 类：Anthropic Messages +
`web_search_20250305` 服务端工具、结果块解析、错误分类、取消语义都由它承担，
本包只负责选实例和给 options。

## 接线

`pkgs/dsh-local/default.nix` 把它编成 bundle 并放进 `webBundles`（仅 web profile）。
它的 patch 做两件事：

1. `insert` 注册行 `web-search-route`；
2. 覆盖 `web` 行，把 `searchProvider` pin 到 `deepseek-route`。

`web` 行的 `config` 是整块替换语义，所以覆盖时必须重复 `fetchProvider: http`，
否则抓取会退回“多个可用 provider”的歧义错误。

## 端点来源

代码里不写端点（本仓库公开）：relay 端点来自 `$DEEPSEEK_RELAY_BASE_URL`（sops 渲染
进 dsh.env，与 LLM 路由同源），官方端点可用 `$DEEPSEEK_SEARCH_BASE_URL` 覆盖。
两者都不含 `/messages`，由上游 provider 追加。

## 验证

1. `nix build .#dsh-web-search-route` 先单独构建 bundle；
   `nix build .#checks.x86_64-linux.dsh-web-search-route` 跑分派回归测试
   （假 ctx + 打桩 fetch，不发真实请求）；
2. rebuild 后重启 `dsh-web`；
3. 会话模型在 `deepseek-relay` 上调用 `web_search`，应命中网关端点：正常工作，
   `deepseek-search-llm-request` 会话事件里的 `endpoint` 指向网关；
4. 切到 `deepseek-official` 再搜一次，事件的 `endpoint` 应变成官方端点；
5. 菜单里能看到 `DeepSeek (route-aware)`，选中即 pin 到 `deepseek-route`。

## 边界

- 只分派 **search**；`web_fetch` 保持 `http`（匿名直连，免费）。
- relay 侧不支持 DeepSeek 账号 token，也不做跨侧回退：relay 挂了不会自动改走官方。
  需要回退时改 `web.searchProvider` 到 `deepseek-official` 或换回上游 provider。
- `ready()` 只检查凭据存在性，不探测端点（与上游一致）。
- 设置页保存的 provider 选择**优先于**组合层：在 Plugins → Web search and fetch 里
  手动选过其它 provider 后，本 bundle 的 `searchProvider: deepseek-route` 会被盖掉，
  选回 `DeepSeek (route-aware)` 或清掉该选择即可恢复。
