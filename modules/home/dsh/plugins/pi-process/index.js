/**
 * pi-process: the `process` tool of @aliou/pi-processes, re-expressed on DSH's
 * own `ctx.jobs` seam.
 *
 * ## 为什么是适配器而不是移植
 *
 * pi-processes 是 pi 的扩展（`@earendil-works/pi-coding-agent` 的 ExtensionAPI +
 * TUI 面板）。dsh 没有 pi 的扩展宿主，所以它的实现一行都不能直接跑。但 agent
 * 真正用到的能力只有一件：起一个长跑进程、别阻塞对话、出事时叫它。dsh 已经有
 * 这套底座（`ctx.jobs` 注册表 + 完成通知 + 环形输出），缺的只是 pi 的**工具面**。
 *
 * 所以这里复刻的是**语义**，不是代码：
 *
 *   - 单工具、多 action（start/list/output/logs/kill/clear/write），与 pi 一致，
 *     这样从 pi 迁过来的 preset / skill / 提示词不用改写法；
 *   - per-process 告警开关（alertOnSuccess / alertOnFailure / alertOnKill）与
 *     运行期输出监听（logWatches）—— 这是 pi-processes 相对裸 jobs 的核心增量；
 *   - 进程句柄仍注册进 `ctx.jobs`，所以 web UI 的 session jobs 列表、会话归档
 *     准入、owner 级联取消全部照旧生效（自己再造一套 manager 就会变成两套生命周期）。
 *
 * ## 明确的边界
 *
 * `write`（向运行中的进程写 stdin）做不到：dsh 的 shell seam 只在**启动时**接受
 * 一段 stdin（`ShellExecRequest.stdin`，写完即关闭），没有暴露运行中的管道。要
 * 交互式喂输入，dsh 的正解是 PTY 的 `terminal_send`。`write` 因此返回一个可操作
 * 的错误，而不是假装成功；`start` 则新增 `stdin` 参数承载"启动时喂一次"这个真实能力。
 *
 * PEER 依赖：@deepseek-ai/* 由 installation 提供（mk-bundle 把 node_modules 链回
 * <runtime>/node_modules），本包零私有运行期依赖。
 */

import z from '@deepseek-ai/schemastery'
import { boundContextSummary, createUserMessage } from '@deepseek-ai/dsh-llm'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { canonicalPath } from '@deepseek-ai/dsh-sandbox'
import { isAbsolute, resolve } from 'node:path'

export const name = 'pi-process'

/** `shell`/`shellEnv` 是启动进程的 seam；`jobs` 是注册表。 */
export const inject = ['tools', 'jobs', 'shell', 'shellEnv']

export const Config = z.object({
  /** `output` 一次返回的最大字节数（尾部截断，超出部分指向 logs）。 */
  maxOutputBytes: z.natural().default(16_384),
  /** 完成告警里内联的上次输出上限。 */
  alertOutputBytes: z.natural().default(2_048),
})

const ACTIONS = ['start', 'list', 'output', 'logs', 'kill', 'clear', 'write']

/** 一个进程在适配器侧的记忆：pi 用友好名索引，dsh 的句柄是 job id。 */
function record(init) {
  return {
    /** 用户给的友好名（pi 的 `name` 是必填项）。 */
    name: init.name,
    command: init.command,
    jobId: init.jobId,
    /** 读取/终止时校验归属用的 session id；无 agent 时为 undefined。 */
    owner: init.owner,
    startedAt: Date.now(),
    alerts: init.alerts,
    /** 每条 watch 带 fired 标记：repeat=false 只报一次。 */
    watches: init.watches,
    /** 模型自己用 kill 停掉的，不告警（pi：killing via tool never triggers a turn）。 */
    killedByModel: false,
  }
}

/** 终止原因投影成 pi 的三种终态。 */
function outcomeOf(proc) {
  if (proc.status === 'killed') {
    return { status: 'killed', detail: proc.signal === null ? 'killed before exit' : `signal: ${proc.signal}` }
  }
  return { status: 'completed', detail: `exit code: ${proc.exitCode ?? 0}` }
}

/** 拉取源：注册表按自己的节奏泵进环形缓冲，这里只做非消费读。 */
function sources(spawned) {
  const source = (channel) => ({
    channel,
    read: (fromByte) => {
      const live = spawned()
      return live === undefined
        ? { text: '', nextOffset: fromByte, lossy: false }
        : live.observed[channel].readFrom(fromByte)
    },
  })
  return [source('stdout'), source('stderr')]
}

/** 环形缓冲读成文本：stdout 连续，stderr 收进一个标注段（与 dsh 的 bash 渲染同形）。 */
function ringText(chunks) {
  const out = chunks.filter((c) => c.channel !== 'stderr').map((c) => c.text).join('')
  const err = chunks.filter((c) => c.channel === 'stderr').map((c) => c.text).join('')
  const separator = out.length > 0 && !out.endsWith('\n') ? '\n' : ''
  return out + (err.length > 0 ? `${separator}[stderr]\n${err}` : '')
}

/** 尾部截断（按 UTF-8 字节），并标注被省略的量。 */
function tailBytes(text, maxBytes) {
  const encoded = new TextEncoder().encode(text)
  if (encoded.byteLength <= maxBytes) return text
  const head = new TextDecoder().decode(encoded.slice(encoded.byteLength - maxBytes))
  return `…[${encoded.byteLength - maxBytes} bytes omitted]…\n${head}`
}

function statusLine(view) {
  const when = view.finishedAt === undefined ? 'running' : `finished ${new Date(view.finishedAt).toISOString()}`
  return `[${view.status}] ${view.kind} ${view.id} — ${view.label} (${when}${view.detail === undefined ? '' : `, ${view.detail}`})`
}

export function apply(ctx, config = {}) {
  const maxOutputBytes = config.maxOutputBytes ?? 16_384
  const alertOutputBytes = config.alertOutputBytes ?? 2_048

  const shell = ctx.get('shell')
  if (shell === undefined) throw new Error('pi-process: the host composition must mount a shell executor (`shell`)')
  const jobs = ctx.get('jobs')
  if (jobs === undefined) {
    throw new Error('pi-process: the host composition must mount a jobs registry (@deepseek-ai/dsh-jobs-local)')
  }

  const shellEnv = ctx.get('shellEnv')

  const defaultMode = shell.sandboxMode
  const sandboxPolicy = defaultMode === undefined ? undefined : ctx.get('sandboxPolicy')
  if (defaultMode !== undefined && sandboxPolicy === undefined) {
    throw new Error('pi-process: the mounted shell executor confines but ctx.sandboxPolicy is missing')
  }
  const resolveSandboxPolicy = (exec) =>
    sandboxPolicy?.resolve(exec.agent === undefined ? {} : { session: exec.agent.session })

  /** jobId → record。列表、告警、clear 都以它为准（注册表里还有别人起的 job）。 */
  const records = new Map()
  /** jobId → 监听扫描到的字节水位。 */
  const cursors = new Map()
  /** jobId → { stdout, stderr } 的未完成行缓冲。 */
  const partials = new Map()

  /**
   * 完成/命中告警：给 owner 开一轮，让它自己决定要不要看。
   *
   * source 必须是**生产者自有**的 kind：session format v4 明确拒绝 `kind: 'plugin'`
   * （"format v4 message requires a producer-owned source kind"），而且那个错误在消息
   * 被 session 采纳时才抛，会把整轮打成 turn error。所以这里用自己的 kind + notice
   * 形状（与 tool-jobs 的完成通知同构），summary 受 dsh-llm 的 120 字符上限约束。
   */
  const deliver = (owner, text, summary) => {
    if (owner === undefined) return
    const agent = ctx.get('agents')?.get(owner)
    if (agent === undefined) return
    try {
      agent.send(
        createUserMessage({
          source: { kind: 'pi-process', form: 'notice', summary: boundContextSummary(summary) },
          content: [{ type: 'text', text }],
        }),
        'next-turn',
        true,
      )
    } catch (error) {
      // 告警是尽力而为：投递失败不能反过来弄坏作业本身。
      console.error('[pi-process] alert delivery failed:', error)
    }
  }

  /** 一条 watch 命中：repeat=false 的只报一次。 */
  const fireWatch = (rec, watch, line) => {
    if (watch.fired && watch.repeat !== true) return
    watch.fired = true
    deliver(
      rec.owner,
      `[process] watch matched on ${rec.name} (${rec.jobId}) — /${watch.pattern}/ ${watch.stream ?? 'both'}\n` +
        `line: ${line.length > 400 ? `${line.slice(0, 400)}…` : line}\n` +
        `Read more: process(action=output, id="${rec.jobId}").`,
      `watch /${watch.pattern}/ matched on ${rec.name}`,
    )
  }

  /** 泵出新字节，按行喂给 logWatches。 */
  const scan = (jobId) => {
    const rec = records.get(jobId)
    if (rec === undefined || rec.watches.length === 0) return
    const from = cursors.get(jobId) ?? 0
    let read
    try {
      read = jobs.readAt(jobId, from, rec.owner)
    } catch {
      return
    }
    cursors.set(jobId, read.next)
    const buffers = partials.get(jobId) ?? { stdout: '', stderr: '' }
    for (const chunk of read.chunks) {
      const channel = chunk.channel === 'stderr' ? 'stderr' : 'stdout'
      const lines = (buffers[channel] + chunk.text).split('\n')
      buffers[channel] = lines.pop() ?? ''
      for (const line of lines) {
        for (const watch of rec.watches) {
          if (watch.stream !== undefined && watch.stream !== 'both' && watch.stream !== channel) continue
          if (watch.regex.test(line)) fireWatch(rec, watch, line)
        }
      }
    }
    partials.set(jobId, buffers)
  }

  /** 结算：按 pi 的开关决定要不要叫醒 owner。 */
  const settle = (event) => {
    const rec = records.get(event.job.id)
    if (rec === undefined) {
      cursors.delete(event.job.id)
      partials.delete(event.job.id)
      return
    }
    // 结算之后注册表还会发一条 `output`（total 不变，只是关闭流）。此时若把游标删掉，
    // 下一次扫描会从 0 重放整圈输出 —— repeat=true 的 watch 就会对同一行再报一次
    // （2026-11-18 实测：probe-watch3 的 READY-MARKER 被报了两次）。所以把游标钉在
    // 终态 total 上，并且先把没有换行结尾的最后一行冲出来。
    const tail = partials.get(event.job.id)
    if (tail !== undefined) {
      for (const channel of ['stdout', 'stderr']) {
        const rest = tail[channel]
        if (rest.length === 0) continue
        for (const watch of rec.watches) {
          if (watch.stream !== undefined && watch.stream !== 'both' && watch.stream !== channel) continue
          if (watch.regex.test(rest)) fireWatch(rec, watch, rest)
        }
      }
    }
    cursors.set(event.job.id, event.job.output.total)
    partials.delete(event.job.id)
    if (event.cause === 'teardown' || rec.killedByModel) return
    const alerts = rec.alerts
    const wanted =
      (event.job.status === 'completed' && alerts.success) ||
      (event.job.status === 'failed' && alerts.failure) ||
      (event.job.status === 'killed' && alerts.kill)
    if (!wanted) return
    let output = ''
    try {
      output = tailBytes(ringText(jobs.readAt(event.job.id, 0, rec.owner).chunks), alertOutputBytes)
    } catch {
      output = ''
    }
    deliver(
      rec.owner,
      `[process] ${rec.name} (${rec.jobId}) ${event.job.status}${event.job.detail === undefined ? '' : ` — ${event.job.detail}`}` +
        (output.length > 0 ? `\n\nLast output:\n${output}` : '') +
        `\n\nRead more: process(action=output, id="${rec.jobId}").`,
      `${rec.name} ${event.job.status}`,
    )
  }

  ctx.effect(() =>
    jobs.events.subscribe({ owners: 'scope' }, (event) => {
      if (event.type === 'output') {
        if (records.has(event.id)) scan(event.id)
        return
      }
      if (event.type === 'settled') settle(event)
    }),
  )

  // 没有 controller 时 `jobs.start()` 会拒绝（上游契约：不能让 owner 收集不到的工作开跑）。
  // 挂上它，这个包就同时是 tool-jobs 的替代品。
  jobs.attachController(name)

  const ownerOf = (exec) => exec.agent?.session.id

  /**
   * 解析一个 id：`view` 是注册表的事实（归属校验由 jobs.get 自己做），`rec` 是本
   * 适配器起的那条的记忆（告警配置、友好名），可能没有 —— `start_process` 之类的
   * 别的生产者注册的 kind=process 作业同样要能被 output/logs/kill 收。
   */
  const targetFor = (id, exec) => {
    const owner = ownerOf(exec)
    if (typeof id !== 'string' || id.length === 0) {
      const available = jobs.list(owner).filter((v) => v.kind === 'process').map((v) => v.id)
      throw new Error(`missing id: pass a process id. Available: ${available.join(', ') || '(none)'}`)
    }
    let view
    try {
      view = jobs.get(id, owner)
    } catch (error) {
      const available = jobs.list(owner).filter((v) => v.kind === 'process').map((v) => v.id)
      throw new Error(`unknown process id: ${id} (${error instanceof Error ? error.message : String(error)}). Available: ${available.join(', ') || '(none)'}`)
    }
    return { id, owner, view, rec: records.get(id) }
  }

  ctx.tools.register(
    defineTool({
      name: 'process',
      description:
        'Manage background processes without blocking the conversation.\n' +
        'Actions:\n' +
        '- start: run a command in the background (requires `name` and `command`). Optional `cwd` (prefer it over `cd dir && …`), ' +
        '`stdin` (written once at spawn, then closed), `alertOnSuccess` (default false), `alertOnFailure` (default true), ' +
        '`alertOnKill` (default false), and `logWatches` (pattern/stream/repeat) to be woken when output matches.\n' +
        '- list: show the processes you started, with ids and statuses.\n' +
        '- output: read retained stdout/stderr for an id (tail-bounded).\n' +
        '- logs: get full-stream file paths when the ring spilled; DSH otherwise keeps output in memory.\n' +
        '- kill: terminate a process (killing it this way never wakes you).\n' +
        '- clear: drop finished processes from the list.\n' +
        '- write: NOT SUPPORTED — DSH has no live stdin pipe. Pass `stdin` at start, or use the PTY `terminal_send` tool for interactive REPLs.\n' +
        'You do not need to poll: completions and watches arrive as notifications. Start the process and continue other work.',
      parameters: {
        action: {
          type: 'string',
          required: true,
          enum: ACTIONS,
          description: 'start | list | output | logs | kill | clear | write',
        },
        name: { type: 'string', description: 'Friendly name (required for start, e.g. "dev-server").' },
        command: { type: 'string', description: 'Command to run (required for start).' },
        cwd: { type: 'string', description: 'Working directory (start); defaults to the session workspace.' },
        stdin: { type: 'string', description: 'Bytes to write to the process stdin once, then close (start).' },
        alertOnSuccess: { type: 'boolean', description: 'Wake the agent when the process exits successfully (default false).' },
        alertOnFailure: { type: 'boolean', description: 'Wake the agent when the process fails to start or crashes (default true).' },
        alertOnKill: { type: 'boolean', description: 'Wake the agent when the process is killed by something other than this tool (default false).' },
        logWatches: {
          type: 'array',
          description: 'Runtime output watches that wake the agent while the process runs.',
          items: {
            type: 'object',
            additionalProperties: false,
            properties: {
              pattern: { type: 'string', required: true, description: 'Regular expression matched against each output line.' },
              stream: { type: 'string', enum: ['stdout', 'stderr', 'both'], description: 'Which stream to watch (default both).' },
              repeat: { type: 'boolean', description: 'Fire every time the pattern matches (default false, one-shot).' },
            },
          },
        },
        id: { type: 'string', description: 'Process id (output | logs | kill | write).' },
        reason: { type: 'string', description: 'Short kill reason, recorded in the job detail (kill).' },
        input: { type: 'string', description: 'Text to write to stdin (write) — unsupported on DSH.' },
        end: { type: 'boolean', description: 'Close stdin after writing (write) — unsupported on DSH.' },
      },
      output: {
        schema: { type: 'string' },
        render: (_args, value) => [{ type: 'text', text: String(value) }],
      },
      presentCall: (args) => ({
        card: 'generic',
        title: `process ${args.action}${args.name === undefined ? '' : ` ${args.name}`}`,
        kind: args.action === 'output' || args.action === 'list' || args.action === 'logs' ? 'read' : 'execute',
        ...(args.command === undefined ? {} : { rawInput: args.command }),
      }),
      async execute(args, exec) {
        switch (args.action) {
          case 'start': {
            if (typeof args.name !== 'string' || args.name.trim().length === 0) {
              throw new Error('invalid name: start requires a non-empty friendly name')
            }
            if (typeof args.command !== 'string' || args.command.trim().length === 0) {
              throw new Error('invalid command: start requires a non-empty command')
            }
            if (exec.signal.aborted) throw new Error('process start aborted')

            const policy = resolveSandboxPolicy(exec)
            const sessionCwd =
              policy?.workspaceRoot ??
              (exec.agent?.session.header.cwd === undefined
                ? undefined
                : canonicalPath(exec.agent.session.header.cwd))
            const workdir =
              args.cwd === undefined
                ? sessionCwd
                : isAbsolute(args.cwd) || sessionCwd === undefined
                  ? args.cwd
                  : resolve(sessionCwd, args.cwd)

            const request = {
              command: args.command,
              ...(workdir === undefined ? {} : { workdir }),
              ...(args.stdin === undefined ? {} : { stdin: args.stdin }),
              dshEnv: shellEnv === undefined ? {} : shellEnv.collect(exec),
              ...(policy === undefined ? {} : { sandboxPolicy: policy }),
            }

            const watches = (args.logWatches ?? []).map((w) => ({
              pattern: w.pattern,
              stream: w.stream,
              repeat: w.repeat === true,
              regex: new RegExp(w.pattern),
              fired: false,
            }))
            const owner = ownerOf(exec)
            /**
             * dsh 0.2.2 的 shell seam 只有 `execute(spec): Promise<ShellExecution>`，
             * 没有同步的 `start()`（旧写法在这里会报 "shell.start is not a function"）。
             * 所以 spawn 是异步的：在 run() 里开一个 AbortController 驱动 prepare+spawn，
             * `done` 覆盖"准备失败"与"进程结束"两段 —— 与 dsh-tool-bash 的后台路径同构。
             * `onExpiry: 'none'`：长跑进程不该被默认超时杀掉。
             */
            const spec = shell.resolve({ ...request, onExpiry: 'none' })
            let spawned
            const jobId = jobs.start({
              kind: 'process',
              label: `${args.name}: ${args.command}`,
              ...(owner === undefined ? {} : { owner }),
              outputLimitBytes: maxOutputBytes,
              output: sources(() => spawned),
              run: () => {
                const controller = new AbortController()
                const done = (async () => {
                  try {
                    spawned = await shell.execute({ ...spec, signal: controller.signal })
                    try {
                      if (controller.signal.aborted) spawned.kill()
                    } finally {
                      await spawned.done
                    }
                    return outcomeOf(spawned)
                  } catch (error) {
                    const killed = controller.signal.aborted && spawned === undefined
                    return {
                      status: killed ? 'killed' : 'failed',
                      detail: error instanceof Error ? error.message : String(error),
                    }
                  }
                })()
                return {
                  done,
                  cancel: (reason) => {
                    if (controller.signal.aborted) return
                    controller.abort(reason)
                    spawned?.kill()
                  },
                }
              },
            })
            records.set(
              jobId,
              record({
                name: args.name,
                command: args.command,
                jobId,
                owner,
                alerts: {
                  success: args.alertOnSuccess === true,
                  failure: args.alertOnFailure !== false,
                  kill: args.alertOnKill === true,
                },
                watches,
              }),
            )
            const watching = watches.length === 0 ? '' : `\nwatching: ${watches.map((w) => `/${w.pattern}/`).join(', ')}`
            return `started ${args.name} → ${jobId}${watching}\nContinue with other work; completion and watch notices arrive automatically.`
          }

          case 'list': {
            // 以注册表为准，而不是本适配器的 records：start_process 之类的别的生产者
            // 起的 kind=process 作业也要能被这里看到和收集。
            const views = jobs.list(ownerOf(exec)).filter((v) => v.kind === 'process')
            if (views.length === 0) return '(no processes in this session)'
            const lines = []
            for (const view of views) {
              const rec = records.get(view.id)
              const detail = rec === undefined
                ? '  (started elsewhere in this session — no alert settings)'
                : `  name: ${rec.name} | alerts: ${
                  [rec.alerts.failure ? 'failure' : '', rec.alerts.success ? 'success' : '', rec.alerts.kill ? 'kill' : '']
                    .filter(Boolean)
                    .join('+') || 'none'
                } | watches: ${rec.watches.length}`
              lines.push(`${statusLine(view)}\n${detail}`)
            }
            return lines.join('\n')
          }

          case 'output': {
            const target = targetFor(args.id, exec)
            let text = ''
            try {
              text = ringText(jobs.readAt(target.id, 0, target.owner).chunks)
            } catch (error) {
              return `${statusLine(target.view)}\n\noutput unavailable: ${error instanceof Error ? error.message : String(error)}`
            }
            const body = text.length === 0 ? '(no output yet)' : tailBytes(text, maxOutputBytes)
            return `${statusLine(target.view)}\n\n${body}`
          }

          case 'logs': {
            const { view } = targetFor(args.id, exec)
            const paths = view.output.spillPaths ?? []
            if (paths.length === 0) {
              return (
                `${statusLine(view)}\n\nno spill files: DSH keeps this process output in the job ring ` +
                `(${view.output.total} bytes total, ${view.output.earliest} retained). ` +
                'Use action=output to read it; a ring that dropped bytes flags them and then names its spill files here.'
              )
            }
            return `${statusLine(view)}\n\nfull-stream files:\n${paths.map((p) => `- ${p}`).join('\n')}\n\nRead them with the read tool; they outlive any ring chunk.`
          }

          case 'kill': {
            const target = targetFor(args.id, exec)
            if (target.rec !== undefined) target.rec.killedByModel = true
            const label = target.rec?.name ?? target.id
            const result = jobs.kill(target.id, target.owner, args.reason)
            return result === 'requested'
              ? `kill requested for ${label} (${target.id})${args.reason === undefined ? '' : ` — ${args.reason}`}\nThis kill does not wake you; check with action=output when you need the tail.`
              : `${label} (${target.id}) had already finished`
          }

          case 'clear': {
            const owner = ownerOf(exec)
            let removed = 0
            for (const view of jobs.list(owner).filter((v) => v.kind === 'process')) {
              if (view.status === 'running' || view.status === 'stopping') continue
              try {
                jobs.remove(view.id, owner)
              } catch {
                // remove 只接受"调用者已自己收集过终态"的作业；失败就留着，不吞记录。
                continue
              }
              records.delete(view.id)
              removed += 1
            }
            return removed === 0 ? 'nothing to clear (no finished processes)' : `cleared ${removed} finished process(es)`
          }

          case 'write': {
            throw new Error(
              'write is not supported: DSH has no live stdin pipe for a running process. ' +
                'Use `stdin` at start for one-shot input, or the PTY `terminal_send` tool for an interactive REPL.',
            )
          }

          default:
            throw new Error(`unknown action: ${String(args.action)} (expected one of ${ACTIONS.join(', ')})`)
        }
      },
    }),
  )
}
