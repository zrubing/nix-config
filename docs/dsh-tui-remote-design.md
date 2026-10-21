# dsh-tui 远程化设计（TUI 作为常驻 core 的客户端）

状态：设计稿，未实施
日期：2026-10-17
基线：dsh 0.2.1-alpha.4 / dsh-tui 0.15.0

## 1. 结论摘要

1. **可行，而且比预想的便宜**：内核自带 Node 客户端（`@deepseek-ai/dsh-api-gateway/client` 的 `node` 入口）与可注入的传输层（`installConnection` + `ClientTransportHooks`），浏览器用的就是同一套；不需要逆向协议。
2. **改造的是 TUI 的 host 层，不是 UI 层**：`AgentSession` + capabilities 这套 backend 缝隙已经由 claude/codex 后端证明可用；远程 dsh 只是再实现一个 backend。
3. **收益不只是"少一份 core"**：远程化后 TUI 不再 import 内核内部包，`0.2.1-alpha.4` 这类"内核改导出形状 → TUI 启动即崩"的故障类别结构性消失；TUI 依赖的是 RPC 契约。
4. **代价**：设置、审批归属、插件管理、`/kernel` 切换这几块要么改走 RPC、要么砍；协议随 alpha 漂移，客户端库必须从**被连的那份安装**里取。
5. **M0 探针已完成**（2026-10-17，见 §12）：数据面（list/create/control/follow/prompt）与最小客户端组合均已验证；审批应答入口与设置面仍待解决。

## 2. 现状：证据与边界

### 2.1 服务端已有完整的远程面

| 事实 | 位置 |
|---|---|
| `/api` 传输（Host/Origin fence + cookie 鉴权） | `dsh-client-connection` 的 `apply`，挂 `/api` 路由 |
| 所有 Remote 流走单一 WebSocket `/api/remote.mux` | `dsh-api-gateway/lib/types/stream-protocol.js` 的 `REMOTE_STREAM_MUX_PATH` |
| Node 客户端（1991 行）与浏览器客户端（2186 行）同源 | `dsh-api-gateway` exports `./client` → `node` / `browser` 条件导出 |
| 客户端以 Cordis 插件安装，产出 `ctx.remote.<namespace>` | `client/index.d.ts`：`apply(ctx)`、`ClientRemote`、`ctx.remote.$host` |
| 连接可注入传输：`fetch` / `openStream` / `createWebSocket` / `streamBaseUrl` / `ownsHost` / `rpc` | `dsh-client-connection/client` 的 `ClientTransportHooks` |
| 事件订阅与应答：`ClientRemoteEvents.subscribe(event, listener)` + `answer` / `dispatchWaterfall` | `client/remote-events.d.ts` |
| 会话流：`session/control` = 一份完整 baseline + 后续 live replacement frames（含 projections：inbox、title、todos、modelSelection、sessionListMetadata、imageLimits…） | `dsh-api-session-controller/lib/typert.remote-client.js` |
| 多客户端：Peer / 每 Peer 访问快照 | `dsh-api-remote-access`（`follow`） |

可调用的命名空间（17 个生成描述符，`typert.remote-client.js`）：

1. `session`：create / list / page / search / prompt / cancel / rename / fork / selectModel / updateQueue / attachment / follow / control / projections / modelCatalog / initializeDefaultModel / openWorkspacePath / canOpenWorkspacePath / workspacePathApplications
2. `skills.list`、`fileReferences.list`
3. `commands.list` / `commands.execute`
4. `goals`：create / edit / get / clear / complete / pause / resume
5. `permission-presets.catalog`
6. `user-questions.answer` / `attachWait`
7. `agent-preset-registry`：list / read / select
8. `plugin-manager`：listPlugins / installBundle / removeBundle / setBundleEnabled / setPluginEnabled / listBundles / listVersionExemptions / setVersionExemption / registries / inspect / cancelInstall / waitForInstall
9. `llm`：listProviders / listConfigurableProviders / discoverModels
10. `subagent`：prompt / interruptByParent
11. `schedule`：catalog / list / update / delete / history
12. `message-feedback`：put / list / delete
13. `file-upload.upload`
14. `session-reference.candidates`
15. `host-plugin-inventory.list`
16. `cordis-host-runner`：13 个（插件运行时面板）

### 2.2 TUI 侧的耦合规模（改造对象）

1. `lib/types/dsh-adapter/`：85 个模块、21.6k 行；全包 1770 个模块、171k 行。
2. 86 个文件直接 `import '@deepseek-ai/*'`；`ctx.get(...)` 触达约 30 个内核服务（agents / sessionPersistence / llm / commands / settings / loader / permissionPresets / credentials / attachments / subagents / approval / agentPresets / shell / sandboxPolicy / planMode / fs / workspaceRegistry / userQuestions…）。
3. 入口线（`host-entry` → `host-dsh`）在进程内做整轮 boot：`app-boot`、`cordis-plugin-loader`、`home-paths`、`profile-boot`、`cmdline`、`launch-environment`、`http-proxy` 八个宿主模块，外加 profile 组合、MCP 握手、模型目录同步。
4. backend 缝隙已经存在：`AgentSession` + `capabilities.native.dsh`；claude / codex 两个外部进程后端就是先例（`lib/types/backends/`）。

## 3. 目标架构

```
        ┌─────────────────────────────┐
        │ dsh-web (systemd, 常驻)     │  ← 唯一 core：profile、插件树、MCP、模型目录、sessions
        │  dsh-host-webserver         │
        │  /api  +  /api/remote.mux   │
        └───────────▲─────────────────┘
                    │ WebSocket（Typert Remote）
        ┌───────────┴─────────────────┐        ┌─────────────────────┐
        │ dsh-tui-remote（fork）      │        │ 浏览器（web UI）     │
        │  Cordis root（仅客户端插件）│        │ 同一份 /api          │
        │  remote backend → AgentSession│      └─────────────────────┘
        │  Ink UI（原样复用）         │
        └─────────────────────────────┘
```

不变量：

1. **一份 core**：只有 dsh-web 进程组合 profile、加载插件、连 MCP。TUI 不再 boot 任何东西。
2. **UI 与数据源解耦**：UI 仍消费 `AgentSession` / channel；新 backend 把远端帧翻译成同一套事件。
3. **版本对齐靠"从被连的安装取客户端库"**：`dsh-tui-remote` 从 `http://127.0.0.1:3080` 对应安装的 node_modules 解析 client 包（与自己同版本），不把客户端库打进自己的包。
4. **本地能力保留**：图片粘贴、终端渲染、主题、快捷键、IDE 通道仍在本进程。

## 4. 协议、鉴权与生命周期

### 4.1 连接建立

1. `installConnection(ctx, { interactions: 'answer', transport: { streamBaseUrl, createWebSocket }, location: { hostname } })`。
2. `interactions: 'answer'` 是审批/提问应答的前提；只读客户端可以用 `none`（`$stream` 要求 answer，被动客户端走生成的流方法）。
3. `streamBaseUrl` 用于非浏览器宿主（Node socket），`createWebSocket` 负责携带鉴权。
4. 鉴权两条路：
   - **上游正规路**：启动 token → `GET /connect?token=…&interactions=answer` → 302 + 签名 cookie → `/api/remote.mux`；或 API operator 凭证。
   - **本仓库现状**：`web-auth-bypass` 内核补丁已把"过了 Host/Origin fence 即放行"落进 `admit()`，回环直连不需要 cookie。设计上仍保留 token 路，避免把回环豁免当成协议前提。
5. 连接代际：`connection.generation` / `connection/reset` 事件；重连后所有 wire-derived 缓存必须重拉，长流自己恢复（`RemoteJournalStream` / `RemoteSnapshotStream` 已内置 resume 语义）。

### 4.2 会话数据

1. `session/control` 是唯一数据源：一份 baseline（projections）+ 后续 replacement frames。
2. 大历史走 `session/page` 分页，不要在流里拉全量。
3. 状态栏（model / effort / preset / todo / queue）直接读 projections，不做客户端 fold —— 这是与现在 in-process 实现最大的差异，也是简化点。

### 4.3 命令

1. prompt / cancel / selectModel / fork / rename / updateQueue / attachment / workspace 路径全部走 unary RPC。
2. 失败语义：`RemoteError`（`code` + `details`）→ 映射到 TUI 现有的错误/toast 通道；不要 `instanceof`。

## 5. 改造清单（TUI 侧）

### 5.1 删除 / 旁路

1. `dsh-adapter/host-entry`、`host-dsh`、`host-contract`：不再组合 profile。保留一个"本地模式"开关，直到远程模式稳定。
2. `host-replica.snapshot.json`、`UPSTREAM_VALIDATED_*` 这套版本指纹：远程化后不再校验内核内部，只校验**协议版本**（由客户端库自带）。

### 5.2 新增

1. `remote/connection`：建 Cordis root、装 connection client、装 `api-gateway/client`、暴露 `ctx.remote`。
2. `remote/backend`：实现 `AgentSession`：
   - `subscribe` / `subscribeRaw` ← `session/control` 帧
   - `history()` ← `session/page`
   - 命令 → `session/*`
   - `capabilities.native.dsh` → 远程等价物（见 5.4）
3. `remote/session-list`：`session/list` + `session/search`，替代 `sessionPersistence.list()`。
4. `remote/auth`：token / operator / 回环三选一；错误呈现到状态栏。
5. `remote/reconnect`：代际重置 + 流恢复 + 正在进行的 turn 的重新对齐（`session/control` 会重发 baseline）。

### 5.3 需要改语义的现有模块

| 模块 | 现在 | 远程后 |
|---|---|---|
| `channel.js` | 从 `Agent` 事件流投影 | 从 `session/control` 帧投影 |
| `fresh-agent.js` | 进程内首次 append 去重 | 由服务端负责；客户端只读 |
| `plugin-manager` 面板 | `ctx.get('pluginManager')` | `ctx.remote.manager.*`（能力齐全，可直接换） |
| `/kernel` 切换 | spawn 另一个内核 | 切换**连接目标**；claude/codex 后端仍是本地子进程 |
| 设置页 | `ctx.get('settings')` 读写 | 见 6 的缺口 |
| MCP 状态 | 进程内插件状态 | `host-plugin-inventory` 或砍 |

### 5.4 capabilities 映射

`attachDshExtensions(core, ctx, native, options)` 期望一个活着的 in-process Agent。远程化有两种做法：

1. **推荐**：新增 `native.remote` 能力包，把现有扩展面板逐个改成"读 projections + 发 RPC"，不复用 `native.dsh`。
2. 不推荐：伪造 `native.dsh` 对象（需要 `Agent` 实例，等于把内核再拉回来）。

## 6. 能力对照（远程有 / 无）

| 能力 | 远程面 | 备注 |
|---|---|---|
| 会话列表 / 搜索 / 分页 | 有 | `session/list`、`session/search`、`session/page` |
| 会话内容 / 状态 / todo / 队列 | 有 | `session/control` projections |
| 发消息 / 取消 / 切模型 / fork / 改名 | 有 | `session/*` |
| 附件 / 图片上传 | 有 | `file-upload`、`session/attachment` |
| 斜杠命令 | 有 | `commands/list`、`commands/execute` |
| goal / schedule / 反馈 | 有 | 各自命名空间 |
| 子代理 | 有 | `subagent.prompt` / `interruptByParent` |
| 插件管理（列/装/卸/启停/豁免） | 有 | `plugin-manager` 全套 |
| 模型目录 | 有 | `llm.*` |
| 提问（ask_user） | 有 | `user-questions.answer` / `attachWait` |
| 审批（sandbox 升级） | **仍未定位** | M0 结果：`control` 投影里只有 `permissions.currentValue`，没有审批请求；宿主侧是 `approval/request` waterfall，转发入口待查 |
| 设置读写 | **未发现客户端面（alpha.4）** | 17 个描述符里没有 `settings`；web 设置页走哪条路需 M0 确认（可能是 plugin-manager / config-editor），否则该面板砍掉或等上游 |
| MCP 服务器状态 | 部分 | `host-plugin-inventory` 可能够；握手细节是宿主私有 |
| 工作区列表 / 应用 | 部分 | `session/workspacePathApplications`、`openWorkspacePath`；侧栏数据源需在 M0 确认 |
| 主题 / 显示偏好 / 快捷键 | 本地 | 不进协议 |
| 图片粘贴 / 终端渲染 | 本地 | 不进协议 |

## 7. 分阶段

### M0 探针（2–3 天，不改 TUI）

1. 一个 ~200 行 Node 脚本：Cordis root + connection client + `api-gateway/client` + 会话描述符。
2. 验收：列会话、`session/control` 跟读一帧流、发一条 prompt、取消一次、应答一次审批（若确认可应答）。
3. 产出：鉴权路径结论、审批应答入口结论、流帧与 projections 的实际形状。
4. **决策点**：M0 失败（例如审批无法远程应答）则整个方案降级为"M1 只读 TUI"，或放弃。

### M1 只读（约 1 周）

1. fork 加 `--remote <url>`；删 host boot，建 connection。
2. 会话列表 + 只读 transcript + 状态栏（读 projections）。
3. 验收：与 web 同开，TUI 能看到 web 正在跑的会话并实时刷新。

### M2 可对话（约 1–2 周）

1. prompt / cancel / selectModel / fork / rename / queue / 附件。
2. 断线重连 + 代际重置 + turn 重新对齐。
3. 验收：两边交替发消息，日志无重复追加，无丢事件。

### M3 审批与提问（约 1 周）

1. 转发事件订阅 + 应答；确定"谁拥有应答权"（TUI 与浏览器同时开着时）。
2. 验收：策略为 `ask` 时，只在 TUI 弹审批也能完成；浏览器那边不重复弹。

### M4 面板收尾（1–2 周）

1. commands / goals / schedules / subagents / presets / llm 目录 / 插件面板。
2. 设置与 MCP 按 6 的结论处理（实现或砍）。

### M5 切换（约 3 天）

1. 仓库侧：默认 `dsh-tui` 指向远程模式；本地模式保留一个版本周期。
2. 删除 `nix-dsh-tui` profile 与 TUI bundle 的装配（省一次内核打包与 500MB bundle）。
3. 验收：删掉 TUI profile 后 TUI 仍工作。

## 8. 风险与缓解

1. **协议漂移**：Typert Remote 是内部协议，每个 alpha 都可能改。
   缓解：客户端库从被连安装解析（同版本）；M0 起把"协议版本"当唯一兼容判据。
2. **单点**：web 服务挂了 TUI 就不能用。
   缓解：systemd 自动重启 + TUI 重连退避 + 本地模式兜底一个版本周期。
3. **并发归属**：两个客户端同一会话，审批/提问可能被任一方应答。
   缓解：M3 明确"首个应答者胜出 + 其余客户端收到 decided 事件"；必要时用 peer 访问控制（`api-remote-access`）。
4. **功能回退**：设置页、插件安装、`/kernel`、MCP 状态。
   缓解：分期交付，先保证"能看能聊"；回退项在 UI 上显式标注不可用，不静默。
5. **fork 维护成本**：上游 dsh-tui 迭代快。
   缓解：改造集中在 `remote/*` 新目录与少量替换点，尽量不改 UI 树；每轮 rebase 只处理 backend 契约。
6. **性能**：大 transcript 的帧体积。
   缓解：`session/page` 分页 + 流只吃增量；渲染层沿用现有虚拟化。

## 9. 仓库侧改动（实施后）

1. `modules/home/dsh`：`dsh-web` 保持常驻；`dsh-tui` 启动器改传 `--remote http://127.0.0.1:3080`。
2. 构建：fork 作为**普通 CLI** 打包（pnpm build + node 运行时），不再是 dsh bundle —— 不需要 `buildDshBundle`、profile、peer 检查、版本豁免。
3. 删除：`nix-dsh-tui` profile、`tuiDisplayBundle`、`capTuiVerifyJobs`、host shim（`mkDshHostPackage`）。
4. 保留：`plugins.tui.enable` 语义改为"安装远程 TUI 客户端"。

## 10. 明确不做

1. 不把 TUI 做成 web 的"第二个 app bundle"（两个 app 抢命令 provider，已在 ACP 上踩过）。
2. 不在客户端重建 profile 组合 / 插件树 / MCP 握手。
3. 不为兼容旧内核保留两套 backend；远程模式只对齐当前安装的协议。


## 12. M0 探针结论（2026-10-17）

探针源码在 `.m0/`（未入库，`.gitignore` 已排除）。环境：沙箱内起 `dsh --profile nix-web --port 3099`（DSH_HOME 为临时副本），Node 24 直连 `/api`。

### 12.1 可用的最小客户端组合

```js
const ctx = new Context()
ctx.plugin({ apply: c => installConnection(c, {
  interactions: 'answer',
  location: { hostname: '127.0.0.1' },
  transport: {
    streamBaseUrl: BASE,                                   // WebSocket mux 的基址
    fetch: (input, init) => fetch(new URL(input, BASE), init), // unary RPC 必须是绝对 URL
  },
}) })
ctx.plugin(typertRegistryClient)   // 提供 ctx.typert
ctx.plugin(apiGatewayClient)       // 提供 ctx.remote
await ctx.remote.$mount(TYPERT_REMOTE)  // 每个 * /lib/typert.remote-client.js 的 default
```

要点：

1. `transport.fetch` 不传时，Node 侧用全局 `fetch` 拼相对路径会报 `Failed to parse URL`；必须自己加基址。
2. 注册描述符要用 `ctx.remote.$mount(info)`，不是 `ctx.typert.remotes.register(...)` —— 后者只登记元数据，不装 `ctx.remote.<ns>` 方法。
3. `ctx.remote.<ns>.<method>` 的调用约定：每个 descriptor 的 `parameters` 逐个作为位置参数；`cancellation` 存在时可多传一个 `AbortSignal`。
4. 流方法返回 `ClientStreamHandle`（`send` / `end` / `dispose` / 单次 asyncIterator）。

### 12.2 已验证

1. `session/list`、`session/create` 正常；`create` 返回 `{sessionId, agentPreset}`。
2. `session/control()` **无参数**，返回 baseline：`{ projections: { <sessionId>: { asOfSeq, values } } }`，即 `control` 是**按 session 聚合的投影流**，不是单会话。
3. `session/follow({ address: { kind: 'session', sessionId }, maxMessages })` 是单会话流：首帧 `snapshot`（header / cursor / records / hasMore / projections / assistantStream），之后是 `event` 与 `assistant-stream` 帧。
4. projections 覆盖：title、goal、tokenUsage、contextPressure、contextBreakdown、inbox、sessionStats、turnOutline、agentPreset、userQuestions、permissions、workingDirectory、subagentCatalog、subagentTiming、subagent、todos、plan、modelSelection、sessionListMetadata、imageLimits。
5. `session/prompt` 的请求体：`{ requestId, sessionId, mode: 'queue'|'steer', content: [{type:'text',text}] }` —— 返回 `{accepted:true}`；随后 follow 流上能看到 `agent/inbox/spliced → turn/start → step/start → request/header → … → step/end → turn/end`。
6. 鉴权：本仓库的 `web-auth-bypass` 补丁下，回环直连**无需 cookie**；未走 `/connect` 换 token。

### 12.3 未验证 / 新发现

1. **模型回复未跑通**：沙箱内 `deepseek-relay` 不可达，turn 在 `step/end` 结束且没有 `assistant/message`。事件链路本身正常，回复需在真实部署验证。
2. **连接建立有 3 次 `connection lost, retry`** 才进入 `connected`（generation id 1）。不是鉴权失败（最终成功且状态为 connected），需在 M1 查是否 WS mux 与 HTTP 服务就绪时序问题。
3. `session/control` 的 baseline 里没有审批请求，只有 `permissions.currentValue` 与 `userQuestions.active`；**审批应答入口仍未定位**。当前证据：宿主 `approval/request` 是 waterfall，`user-questions.answer` 只覆盖 ask-user。

### 12.4 对 M1 的影响

1. 数据面已定：`follow` 负责 transcript，`control` 负责跨会话投影（状态栏/列表徽标）。
2. 传输层已定：一条 WS mux + 一个 `fetch` 包装；重连由 Connection 代际机制处理。
3. 仍需在 M1 解决：审批应答入口、设置面、连接首连抖动。


## 12bis. M1 进展（2026-10-17）

fork 在 `.m1/dsh-tui`（已 gitignore），新增（全部通过 `pnpm compile`）：

1. `src/dsh-adapter/remote/connection.ts` —— 从 PATH 上 `dsh` 的包目录加载客户端库，`installConnection` + `$mount` 会话描述符；可挂到已有 Cordis 根。
2. `src/dsh-adapter/remote/session.ts` —— `AgentSession` 只读实现：`history()` ← 快照 `translateReplay`，`subscribe()` ← `event` / `assistant-stream` 帧；`submit`/`cancel` 在 M1 明确拒绝；附 `listRemoteSessions` / `createRemoteSession` / `promptRemoteSession`。
3. `src/dsh-adapter/remote/startup.ts` —— 复刻 `prepareBackendStartup` 的返回形状（`label/backendId/sessionPrefs/start/persisted/resumeCommand/open/catalog/session/initialHistory`），供 boot 直接当 `backendStart` 用。
4. `src/dsh-adapter/plugin.ts` —— `DSH_TUI_REMOTE_URL` 存在时走 `openRemoteStartup`，跳过 `backendChoice` 与非 DSH 后端加载。
5. `src/dsh-adapter/index.ts` —— `inject` 改为 `{ required: [], optional: ['agents'] }`：裸 Cordis 根没有内核的 `agents` 服务，插件此前根本不会激活。

已验证（沙箱 host，fork 内 probe）：connect / list / create / follow（history=3）/ 跟随中 prompt 收到 18 个实时 `AgentEvent`。

6. `src/dsh-adapter/remote/entry.ts` —— 裸根入口：`new Context()` + `plugin.apply(..., { deferBackendOpen, entryKernel: DSH_BACKEND_ID })`，不组合任何 profile。

pty 冒烟（沙箱 host）：界面正常起来，输入框、状态栏 `DSH · remote`、无 fatal。

实时事件已验证：向 host 发 prompt 后，TUI 的终端标题依次变为 `REMOTE-RENDER-CHECK` → `Remote Render Check`（来自 `user/message` 与 `session/title` 事件），说明 follow 帧确实送达并被投影。

M2 已验证：`submit` 接 `session/prompt`；tmux 真 pty 下输入→回车→host turn→流式回复渲染。`Esc` 触发中断后，界面进入 `⏸ Held · kept after the interrupt`（队列保留语义），说明 channel 的 cancel 路径已调用 `session.cancel`；host 侧终止已确认：`session/cancel` 返回 `ok=true` 后，follow 在 40s 窗口内收到 `turn.end { reason: { kind: 'aborted' } }`。之前的 16s 窗口只是太短（取消要等当前请求返回）。

未完成：① 头部版本显示本地 rc.2（改读 generation）；② `catalog` 仍为 `undefined`；③ 端到端已在 tmux 真实 pty 下验证通过：输入 `hello-from-tui` 回车 → host 开 turn → 模型回复流式渲染（`收到，TUI 链路正常。有什么要做的？`），状态栏显示 `DSH · remote · max · cache 99.1% · nix-config` 与 `ctx 3.2%`；此前「submit 未调用」是 `script` 灌 stdin 的假象（pty 回显，非 App 输入）。④ 调试日志待转正式通道。

## 13. 待决问题

1. 审批与提问的转发事件声明在哪、应答走 `$events/result` 还是别的入口（M0 未定位；提问已由 `user-questions.answer` 覆盖，审批仍缺）。
2. 设置页在 web 上到底走哪条 RPC（决定 TUI 设置页是移植还是砍）。
3. `/kernel` 在远程模式下的语义：切连接目标，还是只保留本地 claude/codex。
4. 是否需要同时连多个 core（本机 web + 远端机器），即"连接配置"是否要做成一等公民。

## 14. 交接（2026-10-17，M2 完成）

### 落点

- fork：`.m1/dsh-tui`（gitignore，v0.15.0 + 本地改动）
- 新增：`src/dsh-adapter/remote/{connection,session,startup,entry,probe}.ts`
- 改动：`src/dsh-adapter/plugin.ts`（`DSH_TUI_REMOTE_URL` 分支 + `openRemoteStartup`）、`src/dsh-adapter/index.ts`（`inject` 改可选）
- 设计文档：本文 §12 / §12bis

### 已验收

1. 裸根入口起界面（无 profile 组合），状态栏显示 `DSH · remote`。
2. 打开 host 上指定会话，`follow` 快照 + 实时帧驱动界面。
3. tmux 真 pty 下：输入 → `session/prompt` → host turn → 流式回复渲染。
4. `Esc` → `session/cancel` → host `turn.end { reason: 'aborted' }`。

### 本地复现（沙箱）

```sh
# host
DSH_HOME=<scratch> dsh --profile nix-web --no-open --host 127.0.0.1 --port 3099 &
# client（客户端库从 PATH 上的 dsh 宿主包解析，需要 host shim）
PATH=<dsh-host-package>:$PATH DSH_TUI_REMOTE_URL=http://127.0.0.1:3099   node --import tsx/esm src/dsh-adapter/remote/entry.ts
# 驱动（必须真 pty；`script` 灌 stdin 只会回显）
TMUX_TMPDIR=<writable> tmux new-session -d -s rt -x 120 -y 40 "<上面的命令>"
tmux send-keys -t rt 'hello' Enter; tmux capture-pane -p -t rt
```

### 未完成

1. **M2 尾巴**：模型切换（`session/selectModel` + `session/modelCatalog`）、队列编辑（`updateQueue`）、附件（`file-upload`）。`capabilities.models` 已实现（`list` ← `session/modelCatalog`、`current` ← 快照 `modelSelection` 投影、`set` ← `session/selectModel`），编译通过；**尚未运行时验证**，尤其 `groups[].id` 是否为 provider 仍需确认。
2. **M3**：提问可走 `user-questions.answer`；**审批仍未定位应答入口**（`control` 投影只有 `permissions.currentValue`，宿主是 `approval/request` waterfall）。这是进入 M3 前必须解决的第一个问题。
3. **M1 收尾**：头部版本仍显示本地 rc.2（应读 host generation）；`catalog` 仍为 `undefined`；`DSH_TUI_REMOTE_DEBUG` 日志待转正式通道。
4. **M4/M5**：面板迁移、仓库侧切换默认并清理 TUI bundle/profile。

## 15. M2 验收（2026-10-17）

### 新增落点

1. `src/dsh-adapter/remote/projections.ts` —— `session/control` 折叠：Host 级单流，一条 `baseline`（全量）+ 每 `(sessionId, key)` 的替换帧。模型选择、权限、标题、todo、问卷队列都在这里。
2. `src/dsh-adapter/remote/catalog.ts` —— `session/modelCatalog` 读取器：进程级一次、按连接缓存，`reasoning(provider, model)` 供 `/effort` 同步取档位。
3. `RemoteConnection` 增加 `projections` / `catalog` 两个成员，连接层各持一份；`openRemoteSession(deps, sessionId)` 接收这两个共享件。

### 关键协议事实（本轮实测）

1. **`session/modelCatalog` 是 0 参数、进程级**的（不是 per-session）。`groups[].id` **就是** provider 路由：实测 2 组，与 `routableProviders` 完全一致，`selectModel({provider: group.id, model})` 被接受。
2. **`session/follow` 的 snapshot 不带 projections**（只有 header/cursor/records）。此前从 snapshot 读 `modelSelection` 恒为 undefined，是错的——现改由 `session/control` 提供。
3. 没有跑过 turn 的会话不记录 `modelSelection`，Host 此时用部署默认；`catalog.default` 就是这条事实，所以 `current()` 在无记录时解析到它（不是兜底值）。
4. `session/selectModel` 返回 `{ selected }`，不是 `{ accepted }`；`reasoningEffort` 可省略（= 该路由默认）。
5. `session/updateQueue` 在 TUI 里**没有消费者**：TUI 的 pending 队列是客户端 FIFO（`PendingMessage`，含中断后的 docked 语义），不是 Host inbox 的编辑器。**从范围里去掉**，不做死代码。

### 已验证

1. 能力层：`models.list` = 67 行（codebuddy 23 + openai 44）；`current()` 读投影；`set()` 切换后投影跟随；`effort.levels()` 随模型变（V3.2 有 off/low/medium/high/max，R1 没有 off）；`effort.set('max')` 后投影为 `max`。
2. UI 层（tmux 真 pty）：`/model` 打开 Host 目录、逐模型显示各自档位（V3.2 六档、R1 五档无 Off）；↓ 选到 DeepSeek R1、→ 两档、Enter 后，**Host 侧确认** `provider=codebuddy model=deepseek-r1 effort=medium`。

### 沙箱操作注意

tmux server 会随 bwrap 父进程退出（`--die-with-parent`），跨调用驱动必须把 tmux 放在受管后台作业里（一条 `while :; do sleep 30; done` 保活），否则下一条 bash 调用拿到 `no server running`。

## 16. M3 审批与提问（2026-10-17）

### 协议事实（读宿主类型定义确认）

1. 审批**不是**一个 RPC 方法。宿主 `dsh-user-approval` 声明 Cordis waterfall `approval/request`（`Scoped<Agent>`，返回 `'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'`，无人应答即 `unavailable`）。
2. 它经 `dsh-api-remotes` 的转发白名单送到 owner 客户端（`mode: 'waterfall'`），客户端用 `ctx.remote.$on('approval/request', (request, next) => …)` 接收，`request = {toolName, callId?, reason?, displayReason?, signal}`。
3. **关键前置**：客户端的 `$on` 分发要先解析 Agent scope —— `typert.contexts.getClient('agent').resolve(agentId)`（`agentId` 就是 sessionId）。没有注册这个 client context 时，监听器**根本不会被调用**，宿主直接落到 fail-closed。这正是 §13 待决问题 1 的答案。
4. 提问同理：`user-questions/request` waterfall，请求 `{questions[], wait?{callId,timed?}, signal}`，回答 `{answers[]}`，每个 answer 用**宿主自己的 question id** 回填。

### 实现

1. `src/dsh-adapter/remote/approvals.ts` —— 一个路由器两个瀑布：注册 client `agent` context（为每个被跟随的会话建一个 `ctx.extend({dshRemoteSessionId})` 作用域），把请求路由到该会话的应答者；未被跟随的 Agent 解析为 `undefined` → 网关跳过分发 → 宿主继续走自己的链（fail closed），不是我们给一个否决票。
2. `session.ts` —— `capabilities.permissions`（`pending` / `respond`）与 `capabilities.questions`（`respond` / `cancel`）：把宿主请求转成 `permission.request` / `question.request` AgentEvent，用户决定后再转回宿主词汇。审批只提供 allow-once / reject 两个选项（协议唯一的授予就是一次）；`allow-always` 被收窄为一次而不是拒绝，拒绝会让宿主一直等。提问按位置进面板、按宿主 id 回答。
3. `connection.ts` —— 连接层各持一份 `approvals`，`close()` 时先 `dispose()`。

### 已验证（`src/dsh-adapter/remote/approval-check.ts`，确定性、不需要宿主）

```
[check] view {"requestId":"approval:s1:1","toolName":"bash","callId":"call-1","reason":"needs to write outside the workspace","options":[{allow-once},{reject}]}
[check] outcome=allowed-once events=permission.request,permission.settled
[check] second outcome=allowed-once
[check] ask {"requestId":"question:s1:1","callId":"call-q","questions":[…2 项…]}
[check] answered={"answers":[{"id":"q-a","selected":["y"]},{"id":"q-b","selected":[],"custom":"note"}]}
[check] ok
```

覆盖：client scope 解析 / 未跟随 Agent 解析为空 / 两个瀑布监听器注册 / 视图形状 / 面板决定回到宿主词汇 / `permission.settled` / 连续两次请求 / 关闭后不再认领（回到 `next()`，即 fail closed）。

### 未验证（环境阻塞，非代码问题）

**真实宿主发起的一次审批没有跑通**：本沙箱的 codebuddy 桥（`http://127.0.0.1:3901/v2`）当前对所有指令都只回一句 "OK"，不产生 tool call，因此无法让宿主发出真的 `approval/request`。换过 `codebuddy/default`、`codebuddy/deepseek-v4-pro`、新建会话、直白到「你必须调用 bash 工具」都无效；`codebuddy/deepseek-v3` 直接 500。等桥恢复后只需一次带写操作的工具调用即可验收这一段。

### M1 收尾项 ① 已解决：头部内核版本

落地页右下角原本显示本仓 node_modules 里的 `v0.2.0-rc.2`（构建依赖的版本），在远程模式下是假话。现在 `installedKernelVersion()` 多一级且排在最前：远程模式读 `findHostDsh()` 解析出的**被连接安装**的 `package.json`——客户端库与协议本来就从那套安装加载，所以它就是服务这个会话的内核版本。实测界面显示 `DSH · dsh-core v0.2.1-alpha.4`。

### 另外两个沙箱陷阱

1. 宿主 `DSH_HOME` 用仓库内 scratch 目录时没有任何凭据（`dsh-tap … static fallback`）：模型路由全部失败。把 `~/.dsh` 的 `codebuddy-plugin-auth.json`、`.credentials.yaml`、`llm-deepseek/`、`router-standard/` 复制进 scratch home 后目录才完整（`~/.dsh` 本身对写只读）。
2. `PATH` 上的 host shim 是**包目录**（`…-dsh-host-package`，里面直接是 `dsh`/`lib`/`node_modules`），不是它的 `bin/`；指到 `bin/` 会让 `findHostDsh()` 退化成 `/etc/profiles/.../bin/dsh` 而报 "launcher script that starts no @deepseek-ai/dsh script"。

## 17. M4 面板与目录（2026-10-17）

### 会话目录（`catalog`）已落地

`remote/sessions.ts`：`session/list` 一次返回全量（无 cwd 过滤、无分页游标），所以工作区过滤放在客户端做；`kind` 由 `origin`/`parentSessionId` 判定，subagent 的 depth 沿同一份列表的父链现场推导，`childCount` 数同一份列表里的子项。

`session/list` **不发布** 会话 header：没有 `createdAt`、没有日志字节数、没有 git 分支记录。所以：

1. `SessionSummary.createdAt` 与 `AgentViewRow.createdAt` 改成**可选**。这是端口形状的根因修正——此前它们假装每个后端都知道创建时间；远端不知道就留空，picking 面板显示 `—`，排序用 `updatedAt` 主键、`createdAt` 仅在存在时参与。伪造一个时间才是补丁。
2. `bytes` / `branch` / `label` 保持 `undefined`（端口本来就允许）。
3. `title.source` 只能是 `'auto'` 或 `'fallback'`：API 只给折叠后的标题，改名和首条自动标题在这里是同一件事；两者都不置灰，视觉上无损。

### 已验证（tmux 真 pty）

1. `/resume` 打开：左侧 `History only · nix-config ✓ 3 sessions`，右侧三行带标题、相对时间、模型（`OK / 6m ago / deepseek-v4-pro` 等），全部来自 Host。
2. ↓ + Enter **切换会话成功**：转写换成另一个会话的历史（含 `[model changed: …]` 分隔行），底栏模型跟着换。
3. 侧栏面板：`/panel` → Todo / Jobs / Agents / Info / Trajectory 都在，Info 面板显示真实数据（标题、cwd、Context 1.1%、窗口 1m、tokens、cache 99.5%、Status idle）。
4. `/status` 输出完整：模型、会话 id、目录、累计 token、缓存率与读取量、turn 计数、上下文占用、标题。

### 本机验证时踩到的两个坑

1. **`~/.dsh-tui` 在沙箱里只读**：切换会话要写 `session-mounts.lock`，写失败时底栏只给出一句带路径的提示，看起来像远端故障。用 `HOME=<workspace>/.m2/tuihome` 启动即可（`utils/paths.ts` 的 `DATA_DIR` 由 `homedir()` 决定）。**这是沙箱限制，不是远程模式的缺陷**。
2. Info 面板的会话 id 原本是 `'#' + id.slice(0, 8)`：DSH 的 id 形如 `session-4842bf2f-…`，截出来恒为 `#session-`。改成先剥掉一个 `word-` 前缀再截（`#4842bf2f`）。这条对本地 DSH 会话同样成立，属于该面板既有的显示缺陷，顺手修在 fork 里。

### 状态栏模型名的根因

底栏与 `/model` 的“当前”标记此前取不到值，因为非 DSH 后端的 `model` getter 会退化成后端名（`DSH · remote`），等首轮 `system/init` 才更新。远端其实**开局就知道**路由：`openRemoteStartup` 现在把 `route`（会话记录的选择，否则宿主部署默认）和 `agentPreset` 挂在启动记录上，`model`/`provider` 两个 getter 优先读它。现在底栏是 `deepseek-v4-pro`，`/model` 里当前行带 ✓。

### 仍缺

1. `/context` 在远程下报“不可用”：它是 DSH 扩展命令，需要 `capabilities.context`，而远端会话没实现。投影里已有 `contextPressure` / `contextBreakdown`，可以实现，但只有三个数（system/tools/messages），没有 files/skills/tools 明细——要不要做取决于是否接受这份不完整的明细。
2. `/fork`、rewind：`session/fork` RPC 存在，但 rewind 还需要恢复工作区文件，远端没有对应面。
3. 附件（`file-upload` 是 agent-scoped，客户端作用域已具备，但 prompt 的图片块映射未做）。
4. Trajectory 面板未逐个点验。

## 18. M5 前置：补丁产物与可重建性（2026-10-17）

### 产物

`pkgs/dsh-tui-remote/remote-mode.patch` —— 对上游 `v0.15.0` 的完整改动（19 文件，+1630/−17），
外加同目录 `README.md`（构建配方 + 还差什么）。补丁**未接进 flake**：本机沙箱 `/nix/store` 只读，
`nix build`/`nix eval` 无法运行（任何求值都要把源码写进 store），所以带 `fakeHash` 的表达式不进树。

### 已验证：补丁可重建

干净 clone `v0.15.0` → `git submodule update --init` → `git apply` → 依赖安装 → 构建 → 连真实宿主：

1. 打补丁后 `tsc` 通过（`gen-backend-index` + `tsc -p tsconfig.json` + `gen-settings-json`）；
2. 入口在 tmux 真 pty 下起来，底栏 `deepseek-v4-pro · cache 98.8% · nix-config`，
   `/model` 里当前行带 ✓，`/resume` 能切会话 —— 与 `.m1` 里的开发副本行为一致。

结论：补丁是自洽的（没有依赖任何未跟踪的本地文件），M5 只差一层 nix derivation。

### 沙箱约束（下次不要重复踩）

1. `/nix/store` 只读 → **nix 构建在本沙箱不可能**；M5 的 derivation 必须在可构建环境里写并验证。
2. `pnpm` 需要可写的 store/cache：`--store-dir <workspace>` + `npm_config_cache=<workspace>`。
   `scripts/build-vendor.mjs` 内部自己调 `pnpm install` 不带 store-dir，在只读 HOME 下必失败；
   等价做法是对 `vendor/dsh-std` 的 7 个包直接跑 `tsc -p tsconfig.json --noEmit && tsdown`。
3. `npx` 的缓存目录、`~/.dsh-tui`（会话挂载锁）都要指到工作区，否则报 EROFS 或“切会话被拒”。

### M5 形状修正

设计 §9.3 说要删 host shim —— **不能删**。客户端库按设计从“被连接的安装”解析，
`findHostDsh()` 要求 PATH 上第一个 `dsh` 能反解出包目录；`/etc/profiles/.../bin/dsh` 是
seed-wrapper（只 exec 另一个脚本），反解不出。所以 shim 留，删的是 `nix-dsh-tui` profile、
`tuiDisplayBundle`、TUI 版本豁免与 `capTuiVerifyJobs`。

## 19. 附件与图片（2026-10-17）

### 协议面（读宿主 schema 确认）

`session/prompt` 的 `content` 有三种块：

1. `{type:'text', text}`；
2. `{type:'image', mediaType, data, name?}` —— **内联 base64**，不需要先上传；
3. `{type:'file', receiptId}` —— 走 `fileUploads/upload` 的回执（该方法是 agent-scoped）。

回放方向还有 `session/attachment({sessionId, attachmentId})` —— 返回“已证明与这条会话日志相关的”图片引用 + base64 字节（`attachmentId/mediaType/bytes/width/height/name?` 加 `data`）。

### 实现

1. `session.ts` 声明 `capabilities.images.limits`（png/jpeg/webp/gif，单张 10MB、单条 20 张 / 30MB、8000px / 40MP）：有这条能力，composer 才把粘贴/拖入的图片暂存在内存里、随 `submit` 以 `AgentInput.images` 交给后端，而不是去找只有进程内才有的 DSH attachments 服务。
2. `submit` 把 `images` 逐张校验后追加为内联 `{type:'image'}` 块（超限抛用户可见的句子，绝不静默丢图）。
3. 翻译器的 `attachments` 从 `() => undefined` 改成真实 reader：回放的图片块带的是**持久引用**，`read()` 经 `session/attachment` 取字节。

### 已验证（真实宿主）

```
[probe] images capability={"mediaTypes":["image/png","image/jpeg","image/webp","image/gif"],"maxImageBytes":10485760,…}
[probe] submit-with-image {"accepted":true}
[probe] projected image {"id":"sha256:c414cd0e…","mediaType":"image/png","width":1,"height":1,"bytes":70,"name":"probe.png"}
[probe] attachment read ok, 70 bytes, png=true
```

即：内联 base64 提交 → 宿主把它落成持久附件（日志里是 `{"type":"image","attachment":{attachmentId:"sha256:…"}}`）→ 回放投影出带尺寸/字节数的 facade → `read()` 经 RPC 取回 70 字节且 PNG 头正确。

一处曾经的误判要记下来：日志里每条用户消息后面还跟一条 `source` 不是 `user` 的“时间戳注入”消息，`history()` 里最后一条 `user.message` 往往是它，所以“最后一条没有 images”不代表图片没落库——要看 `content` 原文。

### 产物同步

`pkgs/dsh-tui-remote/remote-mode.patch` 已按本轮改动重新生成（19 文件，+1764/−17），并在干净 clone 上重跑 `git apply --check`。

## 20. 三处收口（2026-10-17，晚）

### 1. 审批：第一次跑通真实链路（M3 最后一块）

之前一直卡在“模型不产生工具调用”，这次桥恢复了，用一次提权调用打穿整条链。

TUI 里出现的是（真 pty）：

```
──────────── Awaiting approval · bash ────────────
escalate sandbox to danger-full-access: 用户明确授权…
Allow this operation?

❯1. Yes, allow once
  2. No
```

按 Enter 后，宿主**持久日志**（`follow` 快照）给出完整审计对：

```
95  tool/call
96  approval/asked   {"id":"7b5c85d4…","toolName":"bash","callId":"call_00_4rJ…","reason":"escalate sandbox to danger-full-access: …"}
97  approval/decided {"id":"7b5c85d4…","outcome":"allowed-once"}     ← TUI 的 Enter
98  job/registered
99  job/settled
100 tool/result
105 turn/end
```

`outcome: "allowed-once"` 正是我们 `PermissionDecision{kind:'allow-once'} → 'allowed-once'` 的映射结果。工具随即在授权下执行（`touch` 仍因 OS 层只读失败，那是沙箱事实，不是审批链路）。

**M3 至此闭环**：提问走同一套 waterfall（`user-questions/request` → 面板 → 按宿主 id 回填），已由 `approval-check.ts` 覆盖。

### 2. 图片：UI 层也验了

同一次会话里贴入 1x1 PNG：

- 转写渲染出 `[Image · probe.png]` 芯片（回放经 `session/attachment` 取字节）；
- 模型回复 `收到探针图（1x1 深红像素），无任务内容。` —— 它真的看到了图。

### 3. `/context` 已实现并验证

`capabilities.context.usage()` 读 `contextPressure` + `contextBreakdown` 两条投影。TUI 输出与投影数字逐一对上：

```
! /context
  System prompt · 3 sections
  System    1,485 tokens
  Tools     7,289 tokens
  Messages  2,682 tokens
```

（投影原值：`contextPressure={pressureTokens:11305, projectedTokens:11319, contextWindow:1000000}`，`contextBreakdown={systemTokens:1485, toolsTokens:7289, messageTokens:2682}`。）

没有请求过的会话没有 `contextPressure`，此时 `usage()` 直接抛错（面板不显示），不编造 0。

### 剩余

1. `/fork`（`session/fork` RPC 存在）与 rewind（缺工作区文件恢复面）。
2. Trajectory / Jobs / Agents 面板未逐个点验（Todo、Info 已验）。
3. **M5**：补丁与配方就绪，nix 构建需可写 store 的环境。

## 21. `/fork`（2026-10-17）

`session/fork({sessionId, atSeq?})` → `{sessionId}`，宿主把**精确的事件前缀**复制成新会话；省略边界时取最近一个完整 turn。

实现要点：channel 传下来的 `anchor` 就是它 `user.message.anchor`，而 DSH 翻译器把 anchor 定义成 `String(event.seq)` —— 正好是 `atSeq` 要的东西，不需要另找映射。RPC 没有 title 参数，所以带标题的 fork 走 `session/rename` 补上，而不是留个没名字的会话。

实测：

```
[probe] forked -> session-9b32cd9b-2bb6-4688-bdd0-bdfe9f9402ac
[probe] forked history events=108 cwd=/home/jojo/nix-config
[probe] 4 session(s)
  session-9b32cd9b… title="remote fork probe"     ← 标题生效
  session-4842bf2f… title="OK"                    ← 源会话
```

rewind（连工作区文件一起回退）仍然没有对应面：`session/fork` 只复制日志，不改磁盘。这一项维持“不做”。

## 22. 面板清点（2026-10-17）

在同一个远程会话（含 8 个 turn、一条提权调用、一张图片）上逐个打开：

| 面板 | 结果 |
| --- | --- |
| Info | ✅ 真实数据（标题/cwd/Context 1.1%/窗口 1m/tokens/cache 99.5%/idle） |
| Trajectory | ✅ 完整：timeline + hotspot、逐 turn 段（`turn 4 ⋯ 8m06s … 4.7s`）、step、用户提示、助手回复、thinking 标记——全部由 `follow` 的持久日志重建 |
| Todo | 空（该会话没写过 todo，不是缺陷） |
| Jobs | 空：`0 running 0 completed`，且明确写「No background jobs in the current session」。日志里确有 `job/registered`/`job/settled` 一对，但那是前台工具调用的内部记账，不属后台作业 |
| Agents | 空：`No subagents in the current session`（无 Task 委派） |

结论：两个“有数据就渲染”的面板已验证；两个空面板是数据事实，不是链路缺失——它们消费的事件通路与 Trajectory/Todo 同一条（`follow` 帧 → 翻译器 → 投影器）。

至此 M4 的面板项可以收口：`/status`、`/context`、`/model`、`/effort`、`/resume`、`/fork`、Info、Trajectory 均已验；Todo/Jobs/Agents 的渲染依赖会话数据，本环境无法造出（模型桥不回工具调用批次）。

唯一仍标“未做”的是 rewind（工作区文件回退，远程无对应面）。

## 23. 补丁的回归矩阵（2026-10-17）

补丁改了两个共享端口（`SessionSummary.createdAt` / `AgentViewRow.createdAt` 改为可选）、
`plugin.ts` 的两处 getter、`InfoPanel` 的 id 渲染、`sessions/list` 与 `agent-view-projection`
各一行排序。用仓库自带门禁逐个覆盖：

| 脚本 | 结果 |
| --- | --- |
| `verify-adapter-boundary.ts` | OK（1781 源文件 / 7351 import 说明符） |
| `verify-adapter-ports.ts` | OK（19 端口文件 + 24 内核文件，AST 校验） |
| `verify-adapter-channel-conformance.ts` | OK（47 项，官方 fixture + 真实 DSH 投影 + 协议反例） |
| `verify-agent-domain.ts` | OK（24 项） |
| `verify-info-panel.tsx` | OK（43 项） |
| `verify-session-browser.mjs` | all session-screen checks passed |
| `verify-session-list-metadata.ts` | OK（含已装宿主 parity） |
| `verify-session-emptiness.ts` | 通过（含真实 JSONL zstd 往返） |
| `verify-session-mounts.mjs` | 通过（挂载台账） |
| `verify-submit.mjs` | 通过 |
| `verify-resume-manage.mjs` | 通过 |

外加远程自有检查 `src/dsh-adapter/remote/approval-check.ts`（审批 + 提问的确定性回环）。

### M5 的硬阻塞（第 22 轮，条件已持续 5 轮以上）

本沙箱 `/nix/store` 与 `/nix/var/nix` 只读，`nix build` / `nix eval` / `nix flake metadata` 全部无法运行
（求值要把源码写进 store，连 fetcher-cache 都写不了）。因此：

1. `pkgs/dsh-tui-remote/default.nix` 不能写进树 —— 没有可算的 hash，写进去就是一份没人验证过的文件；
2. `modules/home/dsh/default.nix` 的切换（启动器改指远程、删 `nix-dsh-tui` profile 与
   `tuiDisplayBundle`）不能验证 —— 改了却不 build，等于给一台在用的系统留未验证的配置。

M5 的全部前置（补丁、构建配方、仓库侧改动清单、保留/删除项）都已完成，剩下的两步必须在
**可写 nix store 的机器**上做。

## 24. M5 完成：dsh-tui-remote 成为 nix 包（2026-10-18）

`nix build .#dsh-tui-remote` **通过**，产物 `/nix/store/b8yyq0d…-dsh-tui-remote-0.15.0`（998M）。

### 落地

1. `packages/dsh-tui-remote/default.nix`：`fetchFromGitHub` v0.15.0（含 submodules）+ `remote-mode.patch`
   → 两个依赖 FOD → `tsc`/`tsdown` 构建 → `$out/libexec`。
2. 四个 hash 全部落定：源码、pnpm 11.21.0 tarball、根 node_modules FOD、vendor node_modules FOD。
3. `modules/home/dsh` 的 `dshTuiRemote` 改为 `pkgs.callPackage ../../../packages/dsh-tui-remote { }`，
   `DSH_TUI_REMOTE_TREE` 默认 `${pkg}/libexec`——`.m1` 开发树不再被任何配置引用。

### 打包过程中四个实打实的坑

1. **pnpm 11 不在 nixpkgs**：从 npm 取 tarball 用 node 跑；必须补 `passthru.nodejs-slim`，
   否则 `pnpmConfigHook` 的 `inherit (pnpm) nodejs-slim` 直接缺属性。
2. **`fetchPnpmDeps` 会 `--force` 抓所有平台的可选二进制**（claude-agent-sdk / sharp /
   libreoffice-kit，数 GB）→ 网络超时。改为自定义 FOD：`pnpm install` +
   `supportedArchitectures: {os:[linux], cpu:[x64], libc:[glibc]}`。
3. **supply-chain 校验只能在 `pnpm-workspace.yaml` 里关**：命令行 `--config.trustPolicy=off`、
   `--config.minimumReleaseAge=0`、`npm_config_*` 全部无效（`.m2/poltest` 里有最小复现）。
4. **`--no-optional` 会拆掉 esbuild / rolldown 的平台绑定**，`tsx`、`tsdown` 起不来；
   平台限制必须用 `supportedArchitectures`。另外安装产物含指向 `vendor/` 的 workspace
   symlink，`installPhase` 不拷 `vendor/` 会被 `noBrokenSymlinks` 判失败。

hash 抖动问题（FOD 直接产出 node_modules 时）靠把 `HOME` 与 `--store-dir` 钉在 `/build/...`
固定路径解决——pnpm 会把绝对路径写进 `.modules.yaml`。

### 已验证

- `nix build .#dsh-tui-remote` 通过；
- 产物树跑探针连真宿主，列出四个会话（含标题）；
- `nix eval .#homeConfigurations.jojo.activationPackage.drvPath` 求值通过；
- 生成好的 `dsh-tui-remote` 启动器（`result/bin`）在 tmux 真 pty 下启动，底栏
  `deepseek-v4-pro · cache 98.7% · nix-config`。

### 剩余

1. `home-manager switch` 后由用户确认（我这边只验到启动器单独运行）。
2. `.m0` / `.m1` / `.m2` 三个临时目录已无引用，可按用户确认后删除（`.m2/home` 里有我复制的凭据副本，应删）。

## 25. 打包后暴露的耦合：两套框架包并存（2026-10-18）

打包让一个此前只在开发树里存在的状况变成了固定事实。实测（`nix build` 产物 vs 宿主 shim）：

| 包 | 产物树（node_modules，来自 devDeps） | 宿主安装 |
| --- | --- | --- |
| `@deepseek-ai/cordis` | 4.0.4 | 4.0.5-alpha.2 |
| `@deepseek-ai/schemastery` | 3.18.4 | 3.18.5-alpha.2 |
| `@deepseek-ai/dsh-session` | 0.2.0-rc.2 | 0.2.1-alpha.4 |

产物树里静态 `import` 的框架包不少（`cordis` 20 处、`dsh-session` 13 处、`dsh-llm` 12 处……），
而**连接层**（`connection.ts` 的 `createClientRoot` 与客户端库加载）按设计从宿主动态解析。
也就是说运行时确实同时存在两份 Cordis：TUI 自己的模块用 4.0.4，远程连接的根用 4.0.5-alpha.2。

为什么现在能跑：两者之间传的是普通对象与 JSON，没有跨实例的 `instanceof` 校验；`apply` 是普通函数。
为什么仍是隐患：M0 阶段就撞过一次同类问题（两份 host-access 导致 `Cannot redefine property: execute`）。
真正的解法是**所有**框架包都从被连接的安装解析（产物树不打包 `@deepseek-ai/*`），
代价是构建时必须把 devDeps 里的这些包剔出去、并把 `tsc` 需要的类型留在构建期。
这是下一次改动应该做的，不是当前状态的回退——`.m1` 开发树也是这个形状。

### 已验证仍然可用

打包树的探针在同一宿主上列出四个会话（标题正常），启动器在 tmux 真 pty 下渲染并进入会话，
底栏 `deepseek-v4-pro · cache 98.7%`；即版本偏斜目前不影响主链路。

## 26. 打包产物对**真实常驻 core**（3080）的验证（2026-10-18）

此前所有真机验证都打在我起的 scratch 宿主（3099）上。这轮把 `nix build` 的产物直接打到
用户真实的常驻 `dsh web`（3080）上——同一份二进制，同一个 shim，只换 URL：

```
probe list   → 列出真实会话（含历史 id 形态：`12732b3b-…`、`d72991ee-…`、`session-8024b090-…`，
               标题如「升级 mihomo 版本」「排查 nginx gateway fabric 重启原因」）
probe follow → history events=74 cwd=/home/jojo/nix-config，live 帧正常到达
```

两点顺带被验证：

1. `web-auth-bypass` 的回环免 cookie 对客户端库同样成立（没有 token 也能连 `/api`）；
2. `InfoPanel` 的 id 截断修复是必要的——真实会话里确实存在**没有** `session-` 前缀的 id，
   `shortId()` 只在存在前缀时剥一段，两种形态都截得到有意义的尾巴。

## 27. 激活路径的真相：这个仓库的 home-manager 是 NixOS 模块（2026-10-18）

试过两条不需要 root 的路，都不通，记录下来免得下次再绕：

1. **`nix build .#homeConfigurations.jojo.activationPackage` + `activate`**：构建出的代**缺**
   `--trusted-host dsh-zen14.local`（`web.trustedHosts` 设在
   `systems/x86_64-linux/zen14/default.nix`，脱离 NixOS 求值拿不到）。用它激活会悄悄丢掉那条设置。
2. **从 NixOS 模块树里取 `home-manager.users.jojo.home.activationPackage`**：这条能构建出
   **正确**的代（`dsh-web.service` 与当前代逐字节一致，`home-path/bin/dsh-tui-remote`
   指向 `b8yyq0d…/libexec`），`./result/activate` 也把
   `~/.local/state/home-manager/gcroots/current-home` 切到了新代 `2f43dgq0…`，`dsh-web` 未重启；
   但 **PATH 上的 `dsh-tui-remote` 仍解析到 `/etc/profiles/per-user/jojo/bin/`**——那是
   NixOS 用户 profile，只有 `nixos-rebuild switch` 才会更新。

所以最后一步必须 `sudo nixos-rebuild switch --flake .#zen14`（当前账号无免密 sudo）。
在此之前别删 `.m1`：旧启动器仍依赖它。

## 28. 收尾：切换完成、临时目录清空（2026-10-18 11:0x）

用户 `nixos-rebuild switch` 后，PATH 上的启动器已指向 store：

```
/etc/profiles/per-user/jojo/bin/dsh-tui-remote
  DSH_TUI_REMOTE_TREE=/nix/store/b8yyq0d…-dsh-tui-remote-0.15.0/libexec
```

随后删除 `.m0` / `.m1` / `.m2`，共 **5.5G**（11M + 1.2G + 4.3G）。删完复验：启动器直连
3080 列出真实会话，正常。

M5 至此闭环：包在 store 里、配置无开发树引用、临时副本（含 `.m2/home` 的凭据拷贝）全部清掉。
遗留项见 §25（产物树与宿主各带一套 `@deepseek-ai/*`，版本偏斜目前无害，但应在下一次改动里
改成全部从被连接安装解析）。

## 29. 远程模式的两处补全（2026-10-18）

1. **`/compact` / `/plan` 等宿主命令**：客户端原来只挂了 `dsh-api-session-controller` 一个描述符，
   所以 `ctx.remote` 里只有 `session`。补上 `dsh-commands` 描述符，并在 `apply()` **之前**
   `ctx.provide('commands', …)`（channel 绑定时只读一次 `ctx.get('commands')`），
   由 `remote/commands.ts` 按会话缓存宿主 `commands/list` 的结果、`execute` 直通宿主。
   宿主的 `commands/execute` 能跑 `/compact`（实测：`Compacted 5 history items`）。
   另在远程会话的 `capabilities` 上声明 `compact.run()`——TUI 的 `/compact` 路由按这个能力是否存在判定。

2. **「排队」气泡不消失**：`session/prompt` 的 `requestId` 被宿主放在 `user.message.source.rpcId`，
   不是 `user.message.id`；按 id 匹配永远不成立，`pending.changed` 从不发出，气泡常驻。
   `id` 匹配改成 `source.rpcId` 之后仍不稳（宿主回显与本地 pending 的时序），
   最终改为**接受即回收**：`session/prompt` 返回 `ok` 就发 `pending.changed { claimed:[clientMessageId] }`，
   消息从此归宿主所有（已持久化入队、会投影回来）。

验证：scratch 会话连发两条，气泡不再出现；`capabilities.compact.run()` 直接返回 OK。

## 30. 升级验收：契约自检（2026-10-18）

`src/dsh-adapter/remote/verify.ts` 把「客户端依赖宿主的哪些面」写成可执行的断言，
升级 tag 之后先跑它，而不是靠手点。安装后是一条命令：

```sh
dsh-tui-remote-verify                       # 默认打 http://127.0.0.1:3080
dsh-tui-remote-verify http://host:port      # 远端宿主
dsh-tui-remote-verify --no-live             # 只查静态面（描述符 + 方法名）
```

它断言三组事实：

1. **描述符**：`dsh-api-session-controller`、`dsh-commands` 两个
   `typert.remote-client.js` 存在于宿主安装里并能挂载。
2. **方法名**：`remote.session` 的 13 个方法（list/control/follow/prompt/cancel/fork/
   rename/modelCatalog/selectModel/attachment/create/page/projections）与
   `remote.commands` 的 list/execute 全部是函数。
3. **事件契约**：在一次性 scratch 会话里跑一个回合，断言
   - 翻译后事件 `turn.start / user.message / assistant.message / turn.end` 都出现；
   - 原始线路上 `user.message.source.rpcId` 带回客户端 id（§29 的坑）；
   - 会话能力 `compact.run` 存在，`commands/list` 里含 `/compact`。

实测 12/12 通过。失败即契约漂移：要么上游改了方法/字段名，要么宿主版本线不匹配——
两种情况都会在 TUI 里表现为静默错功能（丢事件、命令消失），所以这一步不能省。

## 31. 流式显示：`session/follow` 要显式 opt-in（2026-10-18）

**现象**：远程会话里文本、thinking 都不逐字出现，回合结束时整段一起冒出来；
本地 TUI 没有这个问题。

**根因**：宿主的 `session/follow` 默认只推**持久事件**（`assistant/message` 这类settlement），
逐 token 的瞬态帧要 `request.assistantStream === true` 才订阅：

```js
// dsh-api-session-controller/lib/index.js
const disposeAssistantStream = request.assistantStream !== true ? void 0
  : this.ctx.on('agent/assistant-stream', …)
```

适配器的 `follow()` 没带这个字段，所以 `assistant-stream` 帧从未到达；
`translateFrame`（`backend/translate.ts`）本来就能把帧翻成 `assistant.attempt.start` /
`assistant.delta`（`text` / `reasoning` / `tool-args`），只是没有输入。
TUI 的投影器与渲染器完全没动——本地能流式，说明下游链路是通的。

**修复**：`remote/session.ts` 的 follow 请求加 `assistantStream: true`，
并在 `SessionRemote.follow` 的请求类型里补上该字段。一行行为、一处类型。

**验证**（构建产物直接对 3080 跑，不经 TUI）：

- 文本：`delta:text` 到达，首个 delta 在提交后 ~2.9s，settlement 之后仍在；
- thinking：换 `step-5-preview` + effort `high` 提一个需要推理的问题，
  收到 **105 个 `delta:reasoning`**（首帧 6.9s，随后 40 个 `delta:text`），
  与本地 TUI 的 `assistant.delta{kind:'reasoning'}` 完全同构。

**已知小缺口**：重连/中途 attach 时，宿主在 snapshot 里给的
`assistantStream.activeAttempt.stream`（已累积的紧凑流）适配器没有回放，
所以 attach 那一刻之前的同一段回复只能等 settlement 补齐；正常从回合开始就跟随的场景不受影响。

## 32. 模型切换回显、picker 搜索、footer 显示 provider（2026-10-18）

### 32.1 切模型后底部不变

宿主的 `session/selectModel` 只把选择记进“下一次请求”，**不产生任何客户端可见事件**；
而 TUI 的 footer 读的是 channel state（`state.provider/model`），
远程路径上没有任何东西在切换成功后写它——只有下一回合的 `request/header` 落进日志才会变。

修法（与 claude/codex 后端同构，避免为远程单开分支）：

1. `remote/session.ts` 的 `models.set` 成功后，用宿主返回的 `selected`（已解析的
   provider/model）emit 一个 `model.changed`；
2. `channel/core/session-controls.ts` 的 `observe` 收到 `model.changed` 时写
   `state.provider/model` 并 `emit()`（原来只刷新 modelDisplay/effort）；
3. `routeOverride`：`selectModel` 返回早于 control fold 发布新选择，读投影会慢一拍。
   切换成功先记住本地路由，等 fold 报出同一路由（或别的客户端改了路由）再交还，
   期间 `models.current()`、`effort.levels()` 读到的都是新模型。
4. `effort.set` 同样在成功后 emit `effort.changed`，否则档位读数也要等下一回合。

实测（headless，直接打 3080）：`set(deepseek-official/deepseek-flash)` →
`model.changed{provider:"deepseek-official",model:"deepseek-flash",source:"user"}`，
`current()` 立即是新值；`effort.set("off")` → `effort.changed{effort:"off"}`。

### 32.2 `/model` 列表搜索

打开 picker 后**直接输入**即过滤：大小写不敏感匹配 `provider / id / 显示名`；
有查询时跨 provider 搜全量目录（行首带 `provider /`），清空后回到原来的 tab 视图。
`Backspace` 删字符，`Esc` 先清查询、再按才关闭。标题行右侧显示 `搜索 <query>`，
空查询时该行与旧版逐字节一致（不新增布局行）。

### 32.3 footer 显示 provider

底部状态行模型段从 `model` 改成 `provider/model`（provider 为空时仍只显示 model）；
hover 详情本来就有 provider，未改。切模后 provider 也会跟着变，因为 32.1 写的是同一份 state。

## 33. 启动会话按工作区选（2026-10-18）

**现象**：在 workspace B 里启动 `dsh-tui-remote`，打开的是 workspace A 上次用的会话。

**根因**：`openRemoteStartup` 取 `sessions[0]`。宿主的 `session/list` 是**全机**列表，
第一行就是「全机最近用过的会话」——与启动目录无关。`/resume` 的 catalog 反而按
`scope.cwd` 过滤（`sessions.ts`），只有启动这一步漏了。

**修法**：新增纯函数 `startupSessionFor(sessions, cwd)`：

- 跳过 `origin: 'subagent'` 的子代理会话；
- 只保留 `cwd` 相同（去掉尾部 `/` 后比较）的会话；
- 取 `updatedAt` 最大的一条；
- 没有匹配就返回 `undefined`，由调用方在**当前目录**新建（原来的行为是只有全机
  一条会话都没有时才新建）。

`--resume <id>` 仍然优先，不受目录限制。

**验证**（构建产物直接对 3080）：

- 合成数据：`/w/b` 的两条 + 一条 subagent + `/w/a` 一条 → 选中 `/w/b` 里较新的那条；
- 真实：在 `/tmp/ws-one`、`/tmp/ws-two` 各建一个会话，`startupSessionFor` 分别选中各自
  的 id，未知目录返回 `undefined`；契约自检仍 12/12。

## 34. `--model` 启动路由与常驻宿主的 full access（2026-10-18）

### 34.1 远程客户端不可见的两个事实

1. **恢复会话不写路由**：TUI 文档的"恢复的会话沿用其最后一次请求的路由"是**客户端**
   持久化（`~/.dsh-tui/model.json`）的规则；远程模式下路由由 Host 的投影/日志决定，
   `openRemoteSession` 只读 `modelSelection` 投影，客户端写什么都不生效。
2. **宿主的默认模型在 profile 的 `agent-default-model` 行**：网页端设置页与
   `session/selectModel` 写的是同一处，而且是整块替换（档位一起换）。

### 34.2 做法

1. 启动器只搬运 `--model` 到 `DSH_TUI_MODEL` 并从 argv 剔除；解析只在远程入口一处
   （`parseStartupModel`，`<provider>/<model>[:<effort>]`）。
2. `openRemoteStartup` 等该会话的 `modelSelection` 投影出现（Host 只在该会话有事件后
   发布投影），与请求的路由不符才写；写前读 `agentDefaultModel` 整份 config，写后
   原样恢复。档位优先级：命令行 `:<effort>` > `/effort` 持久化 > 宿主默认档位。
3. `/new` 新建的会话同样落到该路由；之后从浏览器挑别的会话不受影响。

### 34.3 宿主的 full access

base 的三处权限（`sandbox-policy.mode` / `approval.policy` / `permission-presets`）只在
CLI 线读 `DSH_PERMISSION_MODE`，而 `dsh-web` 由 systemd 拉起、没有这个变量 →
此前宿主默认 `workspace-write + ask`，远程客户端因此会收到审批请求。

修法：web profile 追加一个 `dsh-web-permission` bundle（`modules/home/dsh`），把
`sandbox-policy.mode` 写成 `danger-full-access`、`approval.policy` 写成 `never`。
默认预设不另写 —— `dsh-permission-presets` 的 `derive()` 从沙箱模式 + 审批策略推出
`danger-full-access`（新会话据此写 `permission/preset` 等事件，TUI 模式指示器读它）。
权限字段都是 volatile，设置页写入 profile 后以 profile 层为准。

## 35. 底栏显示思考档与权限模式（2026-10-18）

两个字段本来就在 dsh-tui 的状态行里，缺的是开关：

1. `statusBar.thinking`（思考档，`max` 等）默认 true —— 已开；
2. `statusBar.mode`（权限模式）默认 false。开了也只是"有标记才画"：非基准模式（计划、
   完全访问）本来就显示，这个开关真正开启的是基准「默认」模式的常驻显示，于是两种状态
   都看得见。

改在 `modules/home/dsh` 的 `tuiDisplayRow`（从安装树的上游 `cordis.patch.yml` 提取整份
`dsh-tui` config 再覆盖），所以是部署层 seed：设置页改名后以 profile 层为准。

远程会话也会显示：`local-dsh` 通道认领远程会话时把配置的 `modes` 初始成基准模式
（`dsh:default`），权限由 Host 决定，客户端只渲染 —— 状态栏显示的不是客户端自己的开关。

## 36. 远程会话的 `/permission`（2026-10-18）

现象：`dsh-tui-remote` 里 `/permission` 不是命令，回车会把它当普通消息发给模型；
`/` 菜单和 Tab 补全里也没有这一项。带参数直接敲 `/permission workspace-write`
同样被当成文本。

根因不是权限预设读不到，而是**命令表里根本没有 `permission`**：

1. 远程会话的 `capabilities.native` 是 `{}`，`attachDshExtensions` 不会挂载
   （它只认 `native.dsh`）。DSH 的 `permissionPresets` 服务、`/permission` 注册表行、
   命令合并都在这层扩展里，所以远程模式一个都没有。
2. 非 DSH 后端的 `channelCapabilities.commands` 只在 `caps.modes !== undefined` 时
   追加 `permission`（`BACKEND_PERMISSION_COMMAND`）。远程会话当时没有 `modes`，
   于是命令表只有本地命令，`tryRunCommand` 找不到 `permission`，按普通文本提交。
3. 之前只补 `permissionPresets` 服务也不够：那个服务只被 DSH extensions 消费；
   远程模式没有 extensions，服务再完整也不会进命令表。

修法（`permission-presets.patch`）：把 Host 的预设表投影成远程会话本来就有的 typed
`modes` 能力，而不是复活 DSH 扩展。

1. `connection.ts` 额外挂载 `@deepseek-ai/dsh-permission-presets/lib/typert.remote-client.js`
   （可选：老 Host 没有这个命名空间时 import 失败即跳过，连接不受影响），并把
   `permissionPresets/catalog` 读成 `RemotePermissionCatalog`。
2. `session.ts` 在 `permissionCatalog` 存在时声明 `capabilities.modes`：
   `list()` 来自 catalog，`current()` 读 `session/control` 的 `permissions.currentValue`，
   `set(id)` 执行官方 `/permission <id>` 命令并等投影确认。客户端不写
   `permission/preset` 事件。
3. `modes` 一出现，`channelCapabilities.commands` 自动加入 `permission`；`/permission`
   无参走 `backendPermissionCommand` 的 `ModePicker`，带参直切，`Shift+Tab` 走
   `core/actions.ts` 的 `cycleMode`（按 `modes.list()` 顺序）。
4. `auto` 从 `modes` 里排除：它的 session 级风险确认只存在于 DSH 的权限预设选择器，
   当作普通 backend mode 会绕过风险门。

已验证（本沙箱，宿主 `127.0.0.1:3080`）：

1. `verify.js --no-live`：8/8，`permission catalog: read-only, workspace-write,
   danger-full-access`。
2. 真实会话：`modes.list()` 三项，`modes.current()` = `workspace-write`。
3. tmux 真 pty：`/permission` 打开「Permission mode」选择器（本地化标签 + 描述），
   ↑ + Enter 切到 Read-only，状态栏与 `Mode → Read-only` 通知同时更新。
4. 同一会话 `Shift+Tab`：Workspace read/write → Full access → Read-only，顺序与
   `modes.list()` 一致。

### 36.0 Nix 构建（2026-10-18）

`nix build .#dsh-tui-remote` 通过，产物
`/nix/store/r0dmn71jwn825wyd90l2m2r4gckj2ss5-dsh-tui-remote-0.16.1`。
第一次跑暴露了三件 Nix 侧的事实，均已修：

1. `git+file` flake 只把**已跟踪**文件拷进 store。`permission-presets.patch` 最初是
   untracked，derivation 求值直接报 "path … does not exist"；`git add` 后才可见。
2. 客户端 `~/.cache/nix` 在沙箱里只读，`XDG_CACHE_HOME` 指到 workspace 后 fetcher
   缓存可写；store 由 daemon 写，不受根文件系统只读影响。
3. 两个依赖 FOD 的 hash 已漂移：`ROOT_HASH` → `sha256-ifTk1VKj…`，
   `VENDOR_HASH` → `sha256-L0gXffTf…`。这是 0.16.1 依赖树的真实输出，不是补丁导致的。

Nix 产物上重跑 `verify.js --no-live`：8/8；在 tmux 真 pty 里用
`DSH_TUI_REMOTE_TREE=<store>/libexec dsh-tui-remote` 打开 `/permission`，选择器与
本地化标签正常。

补丁也已用 `git apply --check` 在 `v0.16.1 + remote-mode.patch` 上验证干净套用。

### 36.1 `startup-model.patch` 暂停接入

构建清单里移除了 `startup-model.patch`，原因有两条，都是硬事实：

1. 补丁按旧版源码行号生成（`session.ts:1556` 的 `close()`），v0.16.1 的
   `src/dsh-adapter/remote/session.ts` 只有 693 行；`patch --dry-run` 7 个 hunk 里
   5 个失败。
2. 它依赖 `agentDefaultModel.readConfig/editConfig`，但 Host 的
   `@deepseek-ai/dsh-agent-default-model` 没有 `typert.remote-client.js`，这个命名
   空间在远程客户端根本挂不上；即使补丁套得上，`--model` 也会在运行时失败。

补丁文件保留，等上游补上远端配置面、并按当时源码重生后再接回；当前 `--model`
会被启动器搬进 `DSH_TUI_MODEL`，但远程入口不读取，等同于未设置。

## 37. 远程会话的 `/preset`（2026-10-20）

### 37.1 协议面（读宿主类型与实现确认）

1. `@deepseek-ai/dsh-agent-preset-registry` 的 remote descriptor 提供三个方法：
   `agentPresets/list` → `{ presets: [{id, isDefault, name?, description?, broken?}] }`、
   `agentPresets/read(id)` → 组合文档、`agentPresets/select(agentId, id)` → 提交后的 id。
2. `select` 就是网页端 preset「座位」走的同一条路：它先读会话的 `turnBoundary`，
   已开过 turn 的直接抛 `agent-preset/locked`；空白会话则 `recompose` 并 append
   `agent-preset/selected`，返回真正提交的 preset id。
3. `session/control` 的 `agentPreset` 投影是 Host 的实时记录；`session/follow` 的
   snapshot header 也带一份（open 时可用，投影帧随后到）。`session/create` 返回的空白
   会话 header 已有部署默认 preset，所以启动时不必等投影。
4. 客户端原来在 `plugin.ts` 把这个值丢了：`resolved` 在 `backendStart` 分支被写成
   `{ agentPreset: undefined }`，`openRemoteStartup` 解析出的 `agentPreset` 没有任何
   消费者。于是 `/preset status` 在远程会话里恒为「未挂载名册」——这不是名册缺失，
   是启动状态没接线。修法是把 `resolved.agentPreset ?? backendStart?.agentPreset`
   交给 `ChannelLaunchOptions.agentPreset`（本地 DSH 路径仍是 `resolveAgent` 的答案）。

### 37.2 接入形状

远程会话没有 DSH extensions，所以 `/preset` 与 `/permission` 同构：把 Host 的 registry
投影成 typed `presets` 能力，由 channel 核心的后端中立层消费。

1. `src/agent/capabilities.ts`：新增 `PresetChoice` / `PresetSwitchOutcome` 与
   `SessionCapabilities.presets { list, current, set }`；`set` 的拒绝带
   `cause: 'locked'`，UI 文案由 channel 决定，能力层只给事实。
2. `src/channel/capabilities.ts` + `src/commands.ts`：`presets` 标志进入
   `ChannelCapabilities`，`LOCAL_COMMAND_REQUIREMENTS` 把 `preset` 的依赖从默认
   `dsh` 改成 `presets`。声明能力的后端因此自动获得 `/preset` 命令、选择器与补全
   入口；没有能力的后端仍旧「不可用」，不静默降级。
3. `src/dsh-adapter/channel/core/actions.ts`：能力层的 `listPresets` / `switchPreset`
   是唯一的非 DSH 实现。DSH 会话由 extensions 的 model actions 覆盖，行为不变。
   - 切换前 `state.working` 时按 `preset-agent-running` 拒绝（与 DSH 门一致）；
   - 已是当前值 → `preset-already-current`，不发 RPC；
   - `refused{cause:'locked'}` → `preset-locked`（会话已开始：composition 固定）；
   - 其它拒绝 → `preset-switch-failed`；
   - 成功 → 写 `state.agentPreset` 并 emit（Host 的 `agent-preset/selected` 事件随后
     还会经投影器再确认一次）。
4. `src/channel/projection.ts`：`preset.selected` 现在也写 `state.agentPreset`。这修的是
   一个既有缺陷——重放日志或另一个客户端切换后，界面仍显示启动时的旧值；转录行
   仍按原语义追加。
5. `src/dsh-adapter/channel/core/session-switch.ts`：后端自己的 `/new` / `/resume`
   采纳候选会话时，从 `candidate.capabilities.presets.current()` 取当前 composition
   （远程 `/new` 之后不再留着上一个会话的 preset）。
6. `src/dsh-adapter/remote/connection.ts`：`agent-preset-registry` 的 descriptor 与
   `permission-presets` 一样按可选挂载；老 Host 缺命名空间时 `presets` 不声明，
   `/preset` 保持不可用，连接本身不受影响。
7. `src/dsh-adapter/remote/session.ts`：`list` 直读 Host 名册；`current` 读
   `session/control` 的 `agentPreset`，回退到打开时的 snapshot header；`set` 调
   `agentPresets/select(sessionId, id)`，把 `agent-preset/locked` 映射成
   `cause: 'locked'`。
8. `src/dsh-adapter/remote/verify.ts`：契约自检新增 `agentPresets` 描述符与方法断言，
   并在 scratch 空白会话上实际切换一次再切回，确认名册与 `select` 都可用。

### 37.3 语义边界：不写默认

本地 DSH 的 `/preset` 在已开始会话上会把选择写进 `~/.dsh-tui/agent-preset.json`
（下次启动的默认）。远程模式**不做**这件事：

1. 那个文件是进程内 DSH 组合的偏好，Host 侧的 `session/create` 从不读它；写它等于
   撒谎（提示「已保存为默认」但下次 `/new` 不生效）。
2. Host 侧的「新会话默认」是 `agent-preset-registry.selectedDefault` 设置项（网页端
   设置页写它）。`/preset` 是会话内切换命令，不是改部署默认的命令；让一个 TUI
   命令全局改 Host 配置超出它的语义，也会影响网页端。
3. 因此远程的 `/preset status` 用 `preset-host-hint`（「新会话默认由 Host 配置决定」）
   取代本地的 `preset-persist-hint`（文件路径），靠 `ChannelCapabilities.presetDefault`
   区分。已开始会话的切换请求得到 `preset-locked`，不会假装保存。

已知窄缺口：`/preset ` 的 Tab 补全在远程只给 `status`。宿主名册是异步 RPC，而补全
路径是同步的；全量名册在选择器打开时读取。要补这一项需要给 channel 增加同步快照，
本轮不做（KISS）。

### 37.4 构建与验证（2026-10-20）

1. `preset-support.patch`（19 文件，+374/−10；含 §37.5 状态栏段与 §38 提问提示）叠在
   `permission-presets.patch` 之上，
   在干净 v0.16.1 上按 `remote-mode → permission-presets → preset-support →
   notification-ghostty-cap` 顺序 `git apply --check` 全通过。
2. `nix build .#dsh-tui-remote` 通过，产物
   `/nix/store/y5hkmxzllih48rmrkzs5hyilm3wkgyi9-dsh-tui-remote-0.16.1`。
3. `verify.js` 对真实 3080：22/22，包括
   `preset roster: router-standard, standard, my-router-standard, ptc, minimal, cordis,
   my-ptc, my-minimal`、`current preset: standard`、
   `agentPresets/select switches a blank session to router-standard` 与切回。
4. 门禁：`verify:i18n`（2035 条）、`verify:boundary`（1804 文件）、
   `verify:adapter-ports`、`verify:agent-capabilities`（67 项）、
   `verify:channel-composition`、`verify-backend-channel`（200 项，新增 9 项 preset 断言）
   全通过。
5. 真 pty（tmux，`DSH_TUI_REMOTE_TREE=<store>/libexec dsh-tui-remote`）：
   - `/preset status` → `Current preset standard` + 「新会话默认由 Host 决定」+ 锁定规则；
   - `/preset` 打开选择器，列出 Host 的 8 个 preset，当前项标 `✓`、默认项标 `(default)`；
   - 选择器选中 `minimal` → 转录横幅 `Agent preset switched: minimal` + toast
     `Preset switched: minimal`；再查 status → `Current preset minimal`；
   - 直接带参 `/preset minimal` 同样生效（另一进程、另一空白会话）；
   - `/new` 之后 status 回到 `standard`（Host 部署默认），说明采纳路径读的是新会话的
     能力，而不是沿用上一个会话的值；
   - 该空白会话跑完一轮后再 `/preset standard` → `Session already started, preset locked
     (current: minimal)`，Host 侧未被改动。

### 37.5 状态栏 preset 段与 tok/s（2026-10-20）

1. `StatusBarConfig.preset`（默认 false）：`StatusLine` 在 mode 段之后画
   `t('status-preset', {name})` → `预设 <id>` / `preset <id>`。`id` 是 `/preset <id>`
   接受的同一个 token；`channel.agentPreset` 为空时整段不画；极简界面的
   `MINIMAL_UI_STATUS_BAR` 继承默认值，不会出现该段。
2. 同步点四处（既有设计就是四处枚举）：`channel-display.ts` 类型、`tuiDisplayPrefs.ts`
   的 `DEFAULT_STATUS_BAR`、`dsh-adapter/index.ts` 与 `dsh-adapter/plugin.ts` 的两份
   schemastery（后者同时驱动 `settingField('statusBar.preset')`），外加
   `settings/definitions.ts` 的 `/settings` 行。
3. tok/s 不是新功能：`statusBar.tps` 早就有（gauge/sparkline + `N tps`，远程由
   `assistant-stream` 帧驱动投影器计算），只是默认关。本轮只在用户设置里开启，不改代码。
4. 用户层（`~/.dsh-tui/settings.json`）写入 `statusBar: { preset: true, tps: true }`；
   这是 `/settings` 写出的同一层，重启后仍生效，随时可在设置页关掉。

## 38. resume 后的在途提问：协议事实与处理（2026-10-20）

### 38.1 现场

用户 resume `session-b1fb5a5e…`（Emacs telega）后消息发不出去，Web 端显示一个未回答
的提问。查日志：`tool/call`（`ask_user_question`，seq 462）之后没有 `tool/result`，
只有 `agent/inbox/spliced`（TUI 发出的消息进了 Host inbox）与 `command/run/done`；
`session/control` 的 `userQuestions` 投影是 `{active:[],settled:[]}`。

### 38.2 根因（两条协议事实）

1. 该部署的 `ask_user_question` 是 **legacy 阻塞模式**：`dsh-tool-ask-user` 的
   `mode` 默认 `legacy`，工具 schema 不含 `timeout`；`dsh-user-questions` 的投影只
   登记“带 timeout 的 timed 调用”，所以这个调用在投影里根本不存在。
2. `user-questions/request` 是 **转发 waterfall**：只发给请求发出时在线的客户端，
   没有重放（`dsh-api-remotes` 的转发白名单里 `mode: 'waterfall'`）。TUI 在提问之后
   才 attach，就拿不到请求对象；`userQuestions/answer` 只接受 `continued` 的 timed
   提问（Host 实现里 `continued(agent)` 过滤），对 legacy 调用返回 false。

结论：这类提问在协议上只能由“收到请求的那个客户端”（此例是 Web）回答；TUI 既不能
显示也不能回答——直到本轮为它补上显示与出路。

### 38.3 处理

1. `remote/session.ts` 打开会话后扫描已翻译历史：收集没有 `tool/result` 的
   `ask_user_question` 调用，从 `argsJson` 解析问题与选项（解析失败静默跳过，绝不抛）。
2. 把 notice 行**直接追加进视图历史（`history()`）**，由 channel 的 replay 画出来。
   不能只在 `subscribe` 时投递一次：启动路径会两次 replay（构造时一次、adoption 时
   又一次，后者前面还有 `resetProjection`），一次性投递会被 adoption 的 reset 抹掉——
   第一版就栽在这里（行确实产生了，但界面上没有）。
3. 三条 notice：问题原文、选项、出路说明（到收到请求的客户端回答；本端 Esc 取消本回合）。
   文案明确“本客户端无法回答”，不提供假按钮。
4. 代价与边界：这是**只读提示**。要让 TUI 真正回答，需要 Host 侧二选一：
   `tool-ask-user` 切 `mode: 'timed'`（超时即 `continued`，TUI 可用
   `userQuestions/answer` 回答），或 Host 给 pending waterfall 做 attach 重放。
   两者都是 Host 语义/实现变更，本包不越界代改。

### 38.4 验证

1. 用户报告的会话（`session-b1fb5a5e…`）在排查途中被 Web 端回答，`tool/result` 已落库，
   因此不再产生提示——这本身也验证了“只有仍未回答的调用才提示”。
2. 造一次确定性的在途提问：scratch 会话里让模型立即调用 `ask_user_question`
   （“Proceed?” / Yes·No），不回答；换一个**后到的**客户端打开同一会话，`history()`
   末尾得到三条 notice：
   `This session is waiting on a question asked before this client attached; this client
   cannot answer it: Proceed?`、`Options: Yes · No`、`Answer it in the client that received
   it (usually the web UI); press Esc here to cancel this turn.`
3. 清理：`session/cancel` 返回 `accepted:true`，该 scratch 回合被取消，不留悬挂会话。
4. Esc 取消路径沿用既有 `session/cancel`（§15 已验）。

## 39. 宿主重启后的"吞消息"：单代流（2026-10-20）

### 39.1 现场

用户在一个 TUI 窗口里连发两条消息，屏幕毫无反应（连自己的话都不出现）；新开一个窗口
却能看到这两条已经发出去，且新窗口同步正常。宿主日志里两条都在（`session-8c55e0d0…`
的 turn 11/12 正常跑完），说明消息不但在，还被处理了。

时间线对得上：窗口 A 于 `17:15:05` 打开，`17:20:15` `dsh-web` 重启，`17:21:48` 起用户
连续输入（`17:22:29`、`17:22:44`、`17:23:03` 三条"继续"），`17:23:14` 开了窗口 B。
窗口 A 的进程至今仍活着，且持有一条**重启之后**新建到 `:3080` 的连接——即连接换代过。

### 39.2 根因

1. 生成式远程方法返回的是**单代流**：`invokeStream` → `ClientStreamHandle`，socket
   一断就以 `RemoteStreamCarrierError` 抛出并 dispose，不重试、不续传。
2. 客户端把 `session/follow` 和 `session/control` 直接当长流迭代，没有重连层，也没有
   订阅 `connection/reset`；`pump` 的 catch 只在 `DSH_TUI_DEBUG=1` 时输出，`projections`
   的 catch 完全静默。
3. 一元 RPC 走 `connection.rpc`，按代重建，所以 `session/prompt` 继续成功。`submit` 又
   在 RPC 确认后立刻撤掉本地预览（`pending.changed claimed`），指望关闭环回显——流一死，
   屏幕上什么都不留。
4. 结果：**能写不能读**。新窗口正常是因为新进程重开一条流、重新拉快照。

### 39.3 修法

1. 用库自带的两层：`ctx.remote.$stream()`（carrier 失败后等新连接代、重开同一请求）+
   `RemoteSnapshotStream`（baseline 重建 + delta 叠加）。`session/follow` 与
   `session/control` 都是"一帧 baseline 加后续 delta"，形状天然吻合。
2. 第一代 snapshot 仍走 `translateReplay` 填 `history()`；后续代交给 `resync()`：
   只重放 `seq > cursor` 的记录（projector 按 seq 去重），并用 snapshot 的
   `assistantStream.revision` 重置帧栅栏——重启后的帧编号从新一代开始，旧栅栏会把它们
   全判成过期。
3. `projections` 收到新 baseline 时整块替换 fold，不合并：宿主重启后旧 cut 的模型/权限
   不该继续显示。
4. 不再静默：超出回放窗口的缺口投 `remote-stream-gap`，重试彻底放弃投
   `remote-stream-lost`。

### 39.4 验证

1. 对照实验（同一脚本、同一场景：建会话 → 发一条 → `SIGTERM` 宿主 → 重启 → 再发一条）：
   - 旧构建：第二条 `session/prompt` 返回 `accepted=true`，但回显永不到达（复现吞消息）；
   - 新构建：连接换代后回显正常到达，`lost=false`。
2. `dsh-tui-remote-verify` 对活宿主 22/22（含一次真实 `session/prompt` 与
   `turn.start → user.message → assistant.message → turn.end`）。
3. 尚未覆盖：断线时间超过宿主回放窗口（200 条 message）时的缺口——现在是**报告**而不是
   补页；要补齐需要 `session/page` 反向翻页，按 KISS 留作后置兜底。

## 40. 断线可见性与中断归属（2026-10-21）

### 40.1 现场

用户反馈：`dsh-tui-remote` 在 `dsh-web` 重启后"直接显示 interrupted"，怀疑没有网页端
那样的自动重连。核对结果分两半：

1. 重连本身是好的。§39 的续传已在构建里；实测（socat 代理掐断 20 s 再放开）画面继续
   流式推进，没有任何报错行。用户机器上 11:05 起的 TUI 进程经历 11:17:02 / 11:18:24 /
   11:27:46 三次 systemd 重启后仍连在 `:3080`。
2. "interrupted" 不是重连失败，是宿主自己的记录：宿主进程死在半路，`dsh-agent-loop`
   在 resume 时用 `dsh-session` 的 `interruptedTurnClosers` 补写
   `turn/end { reason: { kind: 'interrupted' } }`（closer 的时间戳取自最后一条事件，
   所以看起来比重启早几秒）。turn 的执行体在宿主进程里，这一条谁也救不回来——网页端
   拿到的是同一个事件。

真正的问题是"说不清楚"：断线、重连、恢复全程无提示（窗口像死的），而 `aborted`
（用户 Esc）与 `interrupted`（宿主崩溃/重启）共用一句「已打断 · 接下来想让 DeepSeek
做什么？」，把宿主的事故读成了用户的动作。

### 40.2 改法（`remote-link-visibility.patch`）

1. `remote/connection.ts`：`observeLink(ctx)` 从 `ctx.connection.generation` 派生
   `RemoteLink { state, subscribe }`。选 generation 而不是流失败：逻辑流会在新一代之上
   重开，短抖动根本不会冒成流错误，只有 generation 知道"此刻其实没连上"。
2. `dsh-adapter/plugin.ts`：订阅它驱动 `channel.notify`——断线超过 1.5 s 弹常驻提示
   （`timeoutMs: 0`，恢复时手动释放），恢复后换成 2.5 s 的「已重新连上宿主」。1.5 s
   以内不吭声：没丢东西，留一行是噪音。
3. `channel/projection.ts`：`aborted` 保持原文案；`interrupted` 改走
   `interrupted-by-host`——「宿主重启，这一轮没有跑完 · 需要的话再发一次」。

### 40.3 边界

1. 提示只描述**传输**，不承诺 turn 能活过宿主重启——协议里 turn 归宿主所有。
2. 恢复提示是 2.5 s 的一次性通知，不是常驻徽标；状态栏段（`statusBar.*` 那一套四处
   同步点）留作后置，避免为一个瞬态事实加一个永久配置项。
3. 传送层彻底判死（`remote-stream-lost`）仍走 §39 的 notice，两条路径互不覆盖。
