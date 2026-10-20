# dsh-tui-remote

远程模式的 TUI 客户端（`dsh web` 常驻 core 的客户端）。设计与验收记录见
`docs/dsh-tui-remote-design.md` §12–§23、§36。

## 内容

| 文件 | 用途 |
| --- | --- |
| `default.nix` | nix 构建：源码 + 补丁 → store 里的可运行树 |
| `remote-mode.patch` | 对上游 `v0.16.1` **源码**的完整远程客户端改动 |
| `permission-presets.patch` | 叠加在上一份之上：Host 权限预设 → 远程会话 typed `modes`（`/permission`、Shift+Tab） |
| `preset-support.patch` | 叠加在上一份之上：Host agent-preset 名册 → 远程会话 typed `presets`（`/preset`） |
| `notification-ghostty-cap.patch` | 按 Ghostty 固定通知缓冲（title 63 B / body 255 B）截断 OSC 777/9，避免 255 B 盲截切开 UTF-8 |
| `startup-model.patch` | **暂存，未接入构建**：`--model` 启动路由，见下 |

## Ghostty 通知截断

Ghostty 1.3.1 的 apprt 把 OSC 9/777 的 title/body 拷进 `[63:0]` / `[255:0]` 固定
数组，`@min` + `@memcpy` 不检查 UTF-8 边界；中文预览超过 255 B 时可能切在字符中间，
GIO 最终显示 `[Invalid UTF-8]`。本补丁在发送侧按 Ghostty 的缓冲上限截断（grapheme
边界），WezTerm 等其他 OSC 777 终端仍用 2048 B 预算。上游修复在 Ghostty `53c6fdb`
（tip，未进 1.3.1）。

## 权限模式（`/permission`）

远程会话没有内核，也没有 DSH extensions（`attachDshExtensions` 只挂 `native.dsh`）。
因此 `/permission` 不能走 DSH 的 `permissionPresets` 服务，而是走非 DSH 后端本来就有的
typed `modes` 能力：

1. `permissionPresets/catalog` 读 Host 的预设表（`read-only` / `workspace-write` /
   `danger-full-access`），挂载在 `connection.ts` 的可选 descriptor 上；老 Host 没有这个
   命名空间时，`modes` 不声明，`/permission` 保持不可用，连接本身不受影响。
2. `session/control` 的 `permissions.currentValue` 是当前身份；`modes.current()` 直接读它。
3. `modes.set(id)` 执行官方 `/permission <id>` 命令，并等投影确认；客户端不写
   `permission/preset` 事件。
4. 声明 `modes` 后，`channelCapabilities.commands` 自动把 `permission` 放进命令表，
   `/permission`（无参）打开「Permission mode」选择器，`/permission <preset>` 直切，
   `Shift+Tab` 按 `modes.list()` 顺序循环。
5. `auto` 被排除：它的 session 级风险确认只存在于 DSH 的 `/permission` 预设选择器里，
   当作普通 backend mode 展示会绕过风险门。

## Agent 预设（`/preset`）

远程会话同样没有 DSH extensions，所以 `/preset` 不走 `agentPresets` 服务（宿主侧那份），
而是把 Host 的 registry 投影成 typed `presets` 能力：

1. `agentPresets/list` 是名册（含 `isDefault` / `broken`），`connection.ts` 把
   `@deepseek-ai/dsh-agent-preset-registry` 的 remote descriptor 作为可选挂载；老 Host
   没有该命名空间时不声明 `presets`，`/preset` 保持不可用，连接不受影响。
2. `agentPresets/select(sessionId, id)` 是切换：与网页端 preset「座位」同一条路径，
   只允许空白会话；已开始的会话返回 `agent-preset/locked`，适配器映射成
   `refused{cause:'locked'}`，channel 说「已锁定」而不是通用失败。
3. `current()` 读 `session/control` 的 `agentPreset` 投影（Host 的实时记录），快照 header
   只是首帧之前的回退。切换成功后 channel 先写本地状态，随后持久日志里的
   `agent-preset/selected` 事件再经投影器确认（另一个客户端切换也会这样跟上）。
4. 声明 `presets` 后，`channelCapabilities.commands` 自动加入 `preset`：无参打开选择器、
   `/preset <id>` 直切、`/preset status` 显示当前值。
5. **不写默认**：远程模式下新会话由 Host 配置的默认 preset 决定，`/preset` 不碰
   `~/.dsh-tui/agent-preset.json`（那是进程内 DSH 组合的偏好），也不改 Host 的
   `agent-preset-registry.selectedDefault`。`/preset status` 的第二行按
   `backendCapabilities.presetDefault` 选择文案，如实说明「新会话默认由 Host 决定」。
6. Tab 补全在远程只给 `status`：宿主名册是异步 RPC，而补全路径是同步的；选择器打开时
   才拉全量名册。这是刻意保留的窄缺口，不是错误。
7. 状态栏段 `statusBar.preset`（默认关，`/settings → Show agent preset` 开启）：显示
   `预设 <id>`（`id` 就是 `/preset <id>` 接受的那个 token）。后端没有记录 preset 时
   整段不画；极简界面（minimal UI）的固定字段集里不会出现。tok/s 同理走既有的
   `statusBar.tps`（gauge / sparkline + `N tps`），默认关，开启即可，无需另加代码。

## 连接前发出的提问（resume 后无法在 TUI 回答）

Host 的 `ask_user_question` 默认是 **legacy 阻塞模式**（`dsh-tool-ask-user` 的
`mode: 'legacy'`）：它没有 `timeout` 参数，`userQuestions` 投影不登记这类调用；而
`user-questions/request` 这个 waterfall 是**只发在线客户端、不重放**的。于是：

1. TUI 在提问发出之后才 attach（`/resume`、重连）时，既收不到请求，也无法用
   `userQuestions/answer` 回答（那个 RPC 只接受 `continued` 的定时提问）。
2. 会话日志里留下一个没有 `tool/result` 的 `tool/call`，回合一直挂着；此后 TUI 发的
   消息只会进 Host inbox（日志里能看到 `agent/inbox/spliced`），模型不会回复。

本包的处理：打开会话时扫描已翻译的日志，找出未回答的 `ask_user_question` 调用，
在 channel 订阅（历史已经画完）时投递 notice 行——问题原文、选项、以及两条出路：
到收到该请求的客户端（通常是 Web）回答，或在 TUI 按 Esc 取消本回合。notice 不会
假装本端能回答，因为协议上不能。

要真正让 TUI 能回答“连接前发出的提问”，需要 Host 切成 `mode: 'timed'`
（提问进 `userQuestions` 投影，超时后变 `continued`，可用
`userQuestions/answer(sessionId, callId, answer)` 回答）；那是 Host 侧语义变更，
本包暂不代改。

## `/model` 行内提供方前缀

上游只在 `最近使用` 分组里把行写成 `provider / name`，切到真实 provider 标签后退化成
只有 `name`。远程目录里跨网关重名是常态（`deepseek-relay`、`runinfra`、`openrouter`、
`nvidia-nim` 都挂着「DeepSeek V4.1 Flash」这类显示名），只给名字就说不出这行切到哪个
路由。本包的改动：行文本恒为 `provider / name`，与「实时搜索跨全部标签」的分组无关
——搜索命中的行也必须自证属于哪个 provider。

副作用是上游 `verify-model-picker-ui.tsx` 里一对断言（「标签被裁时不显示
`alpha / Short model`」/「标签可见时显示」）的前提消失：它们断言的是前缀只在该补偿
场景出现。改为在 `catalog ready` 处直接断言每行都带前缀，两条 caret 断言只保留 caret
性质。

## `/model` 模糊搜索

`/model` 的过滤器（上游没有，本包加的 type-to-filter）先是大小写不敏感的子串匹配，
现在走 `src/modelSearch.ts` 的模糊匹配：

1. 子序列命中：查询字符按序出现在任一字段即可，`dskfl` 能找到 `deepseek-flash`。
2. 空白分词，各词可落在不同字段：`relay flash` 命中 provider 带 relay、name 带 flash
   的行。每个词都必须命中，缺一即出局。
3. 排序而不是只过滤：每次按键后 caret 落在第一行，所以必须保证「用户正在拼的那行」
   排最前。连续命中（含子串）比零散命中高 500 分起步，字段起点 +60、词边界（`-_. /:`）
   +25、位置越靠后略扣；并列时按目录原序（稳定排序）。
4. 空查询原样返回，不重排标签内的列表。

无头回归是 `scripts/verify-model-search.mjs`（17 项断言，含「只会多出结果、不会藏掉
旧子串命中」的超集性质）；`verify-model-picker-ui.tsx` 另加一段真实终端的搜索用例：
输入 `sm2` 后只剩 `Short model 2` 且带焦点，Esc 先清过滤、再按才关选择器。

## `--model`（暂未接入）

以下为原设计，当前构建不包含该补丁：启动器仍会把 `--model` 的值搬进
`DSH_TUI_MODEL` 并从 argv 剔除，但远程入口不会读取它，等同于未设置。

`startup-model.patch` 保留为草稿，但**不在 `patches` 里**：

1. 它按旧版源码行号生成（`session.ts:1556`），套不上 v0.16.1；
2. 它依赖的 `agentDefaultModel.readConfig/editConfig` 在 Host 侧没有
   `typert.remote-client` 面，运行时也无法工作。

修好这两点前不参与构建，避免整个包被一个未验证的叠加补丁卡死。下面保留原设计说明，
供后续实现时对照。

`dsh-tui-remote --model deepseek-relay/deepseek-flash:max`（`--model=…` 亦可；
裸 `--model` 不带值时与 `DSH_TUI_MODEL` 同用，`dshTui` 同款约定）。

1. 启动器（`modules/home/dsh`）只把值搬进 `DSH_TUI_MODEL` 并从 argv 剔除 —— 不解析，
   否则 TUI 的启动提示词解析会把它当成要发的消息。
2. 远程入口解析成 `{provider, model, reasoningEffort?}`；没写 `:<effort>` 时用本机
   `/effort` 记住的档位，再没有就用宿主默认路由的档位。
3. 打开的会话（含 `/new` 新建的）若不是该路由，走一次 `session/selectModel`。
   该调用会把选择存成**部署默认模型**（`agent-default-model` 行整块替换），所以前后
   各读一次 `agentDefaultModel`，写完原样写回：`--model` 只影响这次启动，不搬动网页端
   的默认模型。恢复失败即失败，不吞。
4. 恢复已有会话时同样按起点校准（文档里"恢复的会话沿用其最后一次请求的路由"在远程
   模式下不成立 —— 那条规则是 TUI 自己的持久化，远程会话的路由由 Host 记录）。

夹具（构造 patch 时已核对，套在 remote-mode.patch 之上）：`entry.ts` 10 行上下文、
`session.ts:1556` 的 `close()` 收尾、`startup.ts` 的 `@@ -14/-21/-31/-94` ——
上游改这几处要跟着改。

## 升级验收

改动 `tag`/`hash` 之后先跑契约自检，再开 TUI 手点：

```sh
dsh-tui-remote-verify                  # 描述符 / 方法名 / 事件字段 / 权限 catalog / preset 名册与切换 / compact
```

全过才算可用；失败说明上游动了客户端依赖的面（见设计文档 §30）。升级时四份补丁都要
在干净的 `tag` 树上 `git apply --check`：`remote-mode.patch` → `permission-presets.patch`
→ `preset-support.patch` → `notification-ghostty-cap.patch`。

## 怎么建

```sh
nix build .#dsh-tui-remote     # 已验证通过（2026-10-19）
```

四个 hash 都已填好（源码、pnpm 11 tarball、根 node_modules FOD、vendor node_modules FOD）。
2026-10-20 实际构建产物：`/nix/store/y5hkmxzllih48rmrkzs5hyilm3wkgyi9-dsh-tui-remote-0.16.1`
（补丁链：`remote-mode` → `permission-presets` → `preset-support` → `notification-ghostty-cap`）；
两个依赖 FOD 的 hash 已按当前 lockfile 的真实依赖树回填。

启动由 `modules/home/dsh` 的 `dshTuiRemote` 包装器负责：`DSH_TUI_REMOTE_TREE` 现在指向
`${dsh-tui-remote}/libexec`，不再依赖 `.m1/` 开发树。

## 打包过程中撞到并解决的四件事

1. **pnpm 11 不在 nixpkgs**：从 npm 取 tarball 直接用，`passthru.nodejs-slim` 必须补
   （`pnpmConfigHook` 会 `inherit (pnpm) nodejs-slim`）。
2. **`fetchPnpmDeps` 会 `--force` 抓所有平台的可选二进制**（claude-agent-sdk / sharp /
   libreoffice-kit，数 GB）→ 网络超时。改成自定义 FOD：`pnpm install` +
   `supportedArchitectures: {os: [linux], cpu: [x64]}`，只取本平台。
3. **pnpm 11 的 supply-chain 校验只在 `pnpm-workspace.yaml` 里能关**，命令行
   `--config.trustPolicy=off` 无效（实测）。FOD 与构建都在清单顶部加
   `trustPolicy: off` / `minimumReleaseAge: 0`。
4. **`--no-optional` 会拆掉 esbuild/rolldown 的平台绑定**，`tsx`/`tsdown` 直接起不来；
   平台限制要用 `supportedArchitectures` 表达，不能用 `--no-optional`。
   另：安装产物里含指向 `vendor/` 的 workspace symlink，`installPhase` 必须一并拷
   `vendor/`，否则 `noBrokenSymlinks` 判失败。

另外：`src/dsh-adapter/remote/entry.ts` 已改为**不静态 import `@deepseek-ai/cordis`**
（改由 `createClientRoot()` 从被连接的安装解析），这是打包自洽的前提，也让 tarball 树
不需要自带框架包。

## 源码路线的构建配方（已在干净 clone 上验证）

```sh
git clone --depth 1 --branch v0.15.0 https://github.com/ccch1mneyyy/dsh-TUI tui
cd tui && git submodule update --init --recursive
git apply /path/to/remote-mode.patch
npm_config_cache=<writable> npx -y pnpm@11 install --frozen-lockfile --ignore-scripts --store-dir <store>
# vendor/dsh-std 的 7 个包必须先构建（scripts/build-vendor.mjs 会自己调 pnpm install，
# 在只读 HOME 的沙箱里会失败；直接跑它们的 tsc + tsdown 等价）
node --import tsx/esm scripts/gen-backend-index.mjs && npx tsc -p tsconfig.json && node scripts/gen-settings-json.mjs
```
