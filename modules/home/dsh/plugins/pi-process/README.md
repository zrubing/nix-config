# dsh-tool-pi-process

把 pi 的 `@aliou/pi-processes` 扩展复刻成 dsh 插件：**单工具 `process`、7 个 action、per-process 告警**，底座是 dsh 自己的 `ctx.jobs`。它自己 `attachController`，所以可以直接**替代** preset 里的 `tool-jobs` 行，而不是只能与它并存。

## 挂载

包名 `dsh-tool-pi-process`，由 `pkgs/dsh-local` 的 `toolPiProcess` 构建（`mkBundle`，`src` 是本目录，patch 为 `[]`，不插行）。本目录因此带着自己的 `package.json`、`test.mjs` 与本文档 —— 与 `braces-sanitize` 等目录形态的插件一致。

**已接线的 preset：`my-standard`。** 它在 `pkgs/dsh-local/presets.nix` 里把上游 `standard.patch.yml` 的 `tool-jobs` 行整行换成 `pi-process`（整体替换 + 键集断言，上游加键就构建失败），并移除了自己的 `start_process` 行 —— 否则那个工具的描述会指向本 preset 已不存在的 `job_output` / `job_list` / `job_kill`。

同一个 preset 还在**已有的** `tool-bash` 行上补 `config: { enableRunInBackground: false }`：后台进程只留 `process start` 一个入口。理由是 bash 的 `run_in_background` 参数描述写死了 "collect with job_output, stop with job_kill"——那两个工具已被换掉，模型拿到 job id 也没有正确的收集指引（作业本身现在 `process list` 看得见，但文案是错的）。注意要改已有的那一行，不能新增同 id 的行（loader 报 `duplicate loader entry id`）。

其它 preset 想照做，三处改动：

```yaml
# 1. 已有的 tool-jobs 行删掉（或 disabled: true）
# 2. 换成 pi-process 行
- id: pi-process
  name: 'dsh-tool-pi-process'

# 3. 在已有的 tool-bash 行上补 config（不要新增同 id 的行）
- id: tool-bash
  name: '@deepseek-ai/dsh-tool-bash'
  config: { enableRunInBackground: false }
```

注意两点：

1. **不要同时删掉 `tool-jobs` 却不换 controller**：`ctx.jobs.start()` 在没有 controller 时拒绝启动。本插件在 `apply` 里 `attachController('pi-process')`，所以它是合格替代品；controller 可多个、name 独立。但与 `tool-jobs` **同时挂载**时要设 `config: { deliverForeignJobs: false }`：两者都会替别人的作业投完成通知，否则同一件事会报两次。
2. **router-standard 类 preset 要同步改阶段表**：`STAGES[3]` 里写的是 `job_list` / `job_output` / `job_kill`。换成 `process` 之后，阶段 3 应改成 `['pwsh', 'bash', 'read_image', 'process']`，否则验证阶段看不到任何后台控制工具。

## 可调参数

`Config` 两个键，默认值在插件里单点定义（schema 默认与 `apply` 的兜底读同一对常量），
preset 不重复声明，需要时才在行里覆盖：

| 键 | 默认 | 作用 |
|---|---|---|
| `maxOutputBytes` | 16384 | `output` 一次返回的尾部窗口（按 UTF-8 字节截断，超出部分指向 `logs`） |
| `alertOutputBytes` | 2048 | 完成告警里内联的上次输出上限 |
| `deliverForeignJobs` | true | 是否替别的生产者注册的作业投完成通知（后台 workflow 的返回值只有这条通路能到模型）；与 `tool-jobs` 同时挂载时设 false |

## 回归测试

`test.mjs` 用假 ctx 驱动 `apply()`，不启动 dsh、不读写 `$DSH_HOME`。覆盖：投递边界
（idle → followup / running → inject）、per-process 告警开关、logWatch 一次性与 repeat、
结算后游标不重放、外来作业的补投与 `clear` 边界、`TOOL_JOBS` 常量缺失时的失败信息。

```bash
# 首选：走 nix，自带 node_modules（bundle 链回 installation 的 @deepseek-ai/*）
nix build .#checks.x86_64-linux.dsh-pi-process

# 直接对着产物目录跑，改一行测一行
node "$(nix build --no-link --print-out-paths .#packages.x86_64-linux.dsh-tool-pi-process)"/lib/node_modules/dsh-tool-pi-process/test.mjs
```

源码树里裸跑 `node test.mjs` 不行：本目录没有 `node_modules`，`@deepseek-ai/*` 解析不到。

## action 对照（pi → 本插件）

| pi | 本插件 | 说明 |
|---|---|---|
| `start`（name/command/cwd/alertOn*/logWatches） | 同名参数 | 进程注册进 `ctx.jobs`，kind = `process` |
| `list` | 同 | 列本会话的**全部**后台作业：含别的生产者起的（后台 workflow 等），那些条目标注 "started elsewhere" |
| `output` | 同 | 读环形缓冲尾部，`maxOutputBytes`（默认 16 KiB）截断；任意作业 id 都可读 |
| `logs` | 同 | 只在溢出时给 spill 文件路径；dsh 的环默认常驻内存 |
| `kill` | 同 | 任意作业 id 都可停；自 kill 不告警（与 pi 的 `killing via tool never triggers a turn` 一致） |
| `clear` | 同 | 只清本会话 `kind = process` 的终态作业；别的工具的作业留给它们自己收（`jobs.remove` 谁都能删，删了那些工具再 `jobs.get` 会抛错） |
| `write` | **不支持** | dsh 无运行中 stdin 管道；用 `start` 的 `stdin`（一次性）或 PTY 的 `terminal_send` |

## 告警语义

与 pi 有一处刻意的不同：

- `alertOnSuccess` 默认 **true**（pi 默认 false）：`my-standard` 已关掉 bash 的后台通道，`process start` 是唯一入口，成功静默会让"起完等通知"的用法直接失效。要静默就显式传 `false`。
- `alertOnFailure` 默认 **true**、`alertOnKill` 默认 **false**，与 pi 一致。
- `logWatches`：`pattern`（正则，逐行匹配）+ `stream`（stdout/stderr/both）+ `repeat`（默认一次性）。
- 投递按 owner 状态选边界（与 `tool-jobs` 的 `completionDelivery` 一致）：`idle` → `followup`（`next-turn` + 唤醒，开一轮）；`running` → `inject`（`next-step`，不额外唤醒）。后者是必须的——`wait_agent` 只检查 `inbox.nextStep`，只投 `next-turn` 的完成通知叫不醒它，等待会跑满超时（实测 3 分钟）。
- 不告警的情况：`teardown` 结算（owner 已销毁）、模型自己 `kill` 的、`event.awaited`（别的消费者已经收过这次结算）。
- **外来作业**（别的生产者注册、本插件没有 record 的）也投完成通知：DSH 里唯一订阅 `settled` 并投递的是 `tool-jobs` 的 completionDelivery，本 preset 把它换掉了，这一职责就落在这里。通知里带 `job.result`（后台 workflow 的返回值），所以 `output` 之后只读得到环形缓冲里的输出，返回值以通知为准。

## 系统提示

`apply` 注册一段 `tool:process`，占用 `TOOL_JOBS` 的 order 槽位（替代被删掉的 `tool:jobs`）：长命令（dev server / build / watcher / log tail）走 `process(start)`，`bash` 只做能在 timeout 内结束的前台命令；起完不要轮询或 sleep；收尾前用 `output` 收结果，不再需要的 `kill` 掉。只靠工具描述时，模型可能先用 bash 的大 `timeoutMs` 跑长命令，撞上限被 kill 才改口。

## 与 `tool-jobs` 的差异

| | tool-jobs | 本插件 |
|---|---|---|
| 工具面 | `job_list` / `job_output` / `job_kill` | 单个 `process` |
| 读取 | 增量（消费游标） | 尾部窗口（非消费，可反复读） |
| 阻塞等待 | `wait` + `timeout_ms` | 无（pi 的取值：用告警代替等待） |
| 告警粒度 | 全局（`completionDelivery` / `maxConsecutiveWakes`） | 每个进程自己的开关 + 输出监听 |
| 外来作业的完成通知 | 投（订阅 `jobs.events` 的 `settled`，带上 `job.result`） | 默认也投（`deliverForeignJobs`，`jobs.read` 取一次 `result`）；与 tool-jobs 同挂时关掉 |
| UI | session header 的 jobs 列表 | 同一个列表（仍注册在 `ctx.jobs`） |

## 实现边界

- 不移植 pi 的 TUI：`/ps` 面板、pin 到 dock、日志覆盖层的搜索/follow。dsh 侧看 live 输出靠 web UI 的 jobs 列表。
- 进程经 shell seam 启动，沙箱策略照旧（`sandboxPolicy` 解析与 `tool-processes` 同款）；不受 `start_process` 影响。
- `output`/`logs`/`kill`/`write` 都校验 owner：跨会话的 id 会被拒。
