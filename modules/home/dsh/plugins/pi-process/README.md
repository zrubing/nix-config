# dsh-tool-pi-process

把 pi 的 `@aliou/pi-processes` 扩展复刻成 dsh 插件：**单工具 `process`、7 个 action、per-process 告警**，底座是 dsh 自己的 `ctx.jobs`。它自己 `attachController`，所以可以直接**替代** preset 里的 `tool-jobs` 行，而不是只能与它并存。

## 挂载

包名 `dsh-tool-pi-process`，由 `pkgs/dsh-local` 的 `toolPiProcess` 构建（`mkTool`，patch 为 `[]`，不插行）。

**已接线的 preset：`my-standard`。** 它在 `pkgs/dsh-local/presets.nix` 里把上游 `standard.patch.yml` 的 `tool-jobs` 行整行换成 `pi-process`（整体替换 + 键集断言，上游加键就构建失败），并移除了自己的 `start_process` 行 —— 否则那个工具的描述会指向本 preset 已不存在的 `job_output` / `job_list` / `job_kill`。

其它 preset 想照做，写两行即可：

```yaml
# 替代 tool-jobs：job_list / job_output / job_kill 三个工具换成一个 process
- id: tool-jobs
  name: '@deepseek-ai/dsh-tool-jobs'
  disabled: true

- id: pi-process
  name: 'dsh-tool-pi-process'
```

注意两点：

1. **不要同时删掉 `tool-jobs` 却不换 controller**：`ctx.jobs.start()` 在没有 controller 时拒绝启动。本插件在 `apply` 里 `attachController('pi-process')`，所以它是合格替代品；两者同时挂也没问题（controller 可多个，name 独立）。
2. **router-standard 类 preset 要同步改阶段表**：`STAGES[3]` 里写的是 `job_list` / `job_output` / `job_kill`。换成 `process` 之后，阶段 3 应改成 `['pwsh', 'bash', 'read_image', 'process']`，否则验证阶段看不到任何后台控制工具。

## action 对照（pi → 本插件）

| pi | 本插件 | 说明 |
|---|---|---|
| `start`（name/command/cwd/alertOn*/logWatches） | 同名参数 | 进程注册进 `ctx.jobs`，kind = `process` |
| `list` | 同 | 只列本会话起的进程（不含别人） |
| `output` | 同 | 读环形缓冲尾部，`maxOutputBytes`（默认 16 KiB）截断 |
| `logs` | 同 | 只在溢出时给 spill 文件路径；dsh 的环默认常驻内存 |
| `kill` | 同 | 自 kill 不告警（与 pi 的 `killing via tool never triggers a turn` 一致） |
| `clear` | 同 | 只清已结束的；`jobs.remove` 拒绝未结束的作业 |
| `write` | **不支持** | dsh 无运行中 stdin 管道；用 `start` 的 `stdin`（一次性）或 PTY 的 `terminal_send` |

## 告警语义

与 pi 一致：

- `alertOnSuccess` 默认 **false**、`alertOnFailure` 默认 **true**、`alertOnKill` 默认 **false**。
- `logWatches`：`pattern`（正则，逐行匹配）+ `stream`（stdout/stderr/both）+ `repeat`（默认一次性）。
- 投递方式是给 owner 开一轮（`agent.send(..., 'next-turn', true)`），所以是"叫我"，不是"等我轮询"。
- 不告警的情况：`teardown` 结算（owner 已销毁）、模型自己 `kill` 的。

## 与 `tool-jobs` 的差异

| | tool-jobs | 本插件 |
|---|---|---|
| 工具面 | `job_list` / `job_output` / `job_kill` | 单个 `process` |
| 读取 | 增量（消费游标） | 尾部窗口（非消费，可反复读） |
| 阻塞等待 | `wait` + `timeout_ms` | 无（pi 的取值：用告警代替等待） |
| 告警粒度 | 全局（`completionDelivery` / `maxConsecutiveWakes`） | 每个进程自己的开关 + 输出监听 |
| UI | session header 的 jobs 列表 | 同一个列表（仍注册在 `ctx.jobs`） |

## 实现边界

- 不移植 pi 的 TUI：`/ps` 面板、pin 到 dock、日志覆盖层的搜索/follow。dsh 侧看 live 输出靠 web UI 的 jobs 列表。
- 进程经 shell seam 启动，沙箱策略照旧（`sandboxPolicy` 解析与 `tool-processes` 同款）；不受 `start_process` 影响。
- `output`/`logs`/`kill`/`write` 都校验 owner：跨会话的 id 会被拒。
