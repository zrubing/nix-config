/**
 * 回归测试：pi-process 的四条不变量。
 *
 * ## 测什么（每条都对应一次实测过的回归）
 *
 *   1. 完成告警按 owner 状态选投递边界：idle → followup（next-turn + 唤醒），
 *      running → inject（next-step）。只投 next-turn 时 `wait_agent` 一直跑到超时
 *      （2026-11-21 实测 15 秒整）。
 *   2. 告警开关是 per-process 的，默认 success/failure 开、kill 关；模型自己 kill
 *      的不叫人。
 *   3. logWatch 默认一次性；`repeat: true` 每行都报。
 *   4. 结算后注册表还会发一条 `output`（total 不变）。游标若在结算时被删掉，下一次
 *      扫描会从 0 重放整圈，repeat 的 watch 对同一行再报一次（2026-11-18 实测）。
 *
 * ## 跑法
 *
 * 需要 `@deepseek-ai/*` 可解析，所以不在源码树里裸跑（同目录没有 node_modules）：
 *
 *     nix build .#checks.x86_64-linux.dsh-pi-process
 *
 * 或者对着产物目录跑（bundle 里有 node_modules → <runtime>/node_modules）：
 *
 *     node "$(nix build --no-link --print-out-paths .#packages.x86_64-linux.dsh-tool-pi-process)"/lib/node_modules/dsh-tool-pi-process/test.mjs
 *
 * 假 ctx 只实现插件真正用到的 seam：`tools` / `jobs` / `shell` / `systemPrompt` /
 * `agents`。jobs 注册表按 dsh-jobs-local 的事件形状投影（`output` / `settled`），
 * 所以测的是适配器与注册表的契约，不是 mock 自己的约定。
 */

import assert from 'node:assert/strict'
import { apply } from './index.js'

const OWNER = 'session-1'

/** 让出若干轮事件循环：插件的 run() 是异步的（shell.execute 返回 Promise）。 */
const tick = async (rounds = 3) => {
  for (let index = 0; index < rounds; index += 1) await new Promise((resolve) => setImmediate(resolve))
}

/** 一条投递消息投影成断言用的形状。 */
function readMessage(message) {
  return {
    summary: message.source?.summary,
    kind: message.source?.kind,
    text: message.content.map((part) => (part.type === 'text' ? part.text : `[${part.type}]`)).join(''),
  }
}

/**
 * 假宿主：一个 jobs 注册表 + 一个 shell executor + 一个 agent。
 *
 * 注册表按 dsh-jobs-local 的约定投影：`start()` 同步返回 id、调用 `spec.run()`
 * 拿 hooks；hooks.done 结算时先发 `settled` 再发 `output`（与上游 settle() 同序）。
 */
function createHost(options = {}) {
  const jobs = new Map()
  const deliveries = []
  const controllers = []
  const registered = []
  const sections = []
  const commands = []

  const agent = {
    status: options.agentStatus ?? 'idle',
    followup(message) {
      deliveries.push({ boundary: 'followup', ...readMessage(message) })
    },
    inject(message) {
      deliveries.push({ boundary: 'inject', ...readMessage(message) })
    },
  }

  let listener
  let seq = 0
  let spawned
  let settleSpawned

  const view = (job) => ({
    id: job.id,
    kind: job.kind,
    label: job.label,
    ...(job.owner === undefined ? {} : { owner: job.owner }),
    status: job.status,
    ...(job.detail === undefined ? {} : { detail: job.detail }),
    startedAt: job.startedAt,
    ...(job.finishedAt === undefined ? {} : { finishedAt: job.finishedAt }),
    output: {
      total: job.total,
      earliest: 0,
      ...(job.spillPaths === undefined ? {} : { spillPaths: job.spillPaths }),
    },
  })

  const emitOutput = (id) => listener?.({ type: 'output', id, total: jobs.get(id).total })

  const finish = (id, status, detail) => {
    const job = jobs.get(id)
    if (job === undefined || job.status !== 'running') return
    job.status = status
    if (detail !== undefined) job.detail = detail
    job.finishedAt = Date.now()
    listener?.({ type: 'settled', job: view(job), cause: 'producer', awaited: false })
    emitOutput(id)
  }

  const registry = {
    start(spec) {
      const id = `${spec.kind}-${++seq}`
      const job = {
        id,
        kind: spec.kind,
        label: spec.label,
        owner: spec.owner === undefined ? undefined : spec.owner,
        status: 'running',
        total: 0,
        text: '',
        startedAt: Date.now(),
      }
      jobs.set(id, job)
      const hooks = spec.run({ id, append() {}, updateProgress() {} })
      job.hooks = hooks
      hooks.done.then((outcome) => finish(id, outcome.status, outcome.detail))
      return id
    },
    list(owner) {
      return [...jobs.values()].filter((job) => owner === undefined || job.owner === owner).map(view)
    },
    get(id, owner) {
      const job = jobs.get(id)
      if (job === undefined) throw new Error(`unknown job ${id}`)
      if (owner !== undefined && job.owner !== owner) throw new Error(`job ${id} belongs to another owner`)
      return view(job)
    },
    readAt(id, from) {
      const text = jobs.get(id)?.text ?? ''
      const pending = text.slice(from)
      return {
        chunks: pending.length === 0 ? [] : [{ channel: 'stdout', text: pending }],
        next: text.length,
        lossy: false,
      }
    },
    /** 消费式读：与 dsh-jobs-local 的 read() 同义，终态作业的 result 只交付一次。 */
    read(id, owner) {
      const job = jobs.get(id)
      if (job === undefined) throw new Error(`unknown job ${id}`)
      if (owner !== undefined && job.owner !== owner) throw new Error(`job ${id} belongs to another owner`)
      const result =
        job.status !== 'running' && job.result !== undefined && job.resultDelivered !== true ? job.result : undefined
      if (result !== undefined) job.resultDelivered = true
      return {
        chunks: job.text.length === 0 ? [] : [{ channel: 'stdout', text: job.text }],
        result,
        job: view(job),
      }
    },
    kill(id) {
      const job = jobs.get(id)
      if (job === undefined) throw new Error(`unknown job ${id}`)
      if (job.status !== 'running') return 'already-finished'
      job.hooks?.cancel('killed by the model')
      return 'requested'
    },
    remove(id) {
      jobs.delete(id)
    },
    attachController(name) {
      controllers.push(name)
    },
    events: {
      subscribe(_filter, callback) {
        listener = callback
        return () => {
          listener = undefined
        }
      },
    },
  }

  const shell = {
    sandboxMode: undefined,
    resolve: (spec) => spec,
    async execute(spec) {
      commands.push(spec)
      spawned = {
        status: 'running',
        exitCode: 0,
        signal: null,
        kill() {
          spawned.status = 'killed'
          spawned.signal = 'SIGTERM'
        },
        observed: {
          stdout: { readFrom: () => ({ text: '', nextOffset: 0, lossy: false }) },
          stderr: { readFrom: () => ({ text: '', nextOffset: 0, lossy: false }) },
        },
        done: new Promise((resolve) => {
          settleSpawned = resolve
        }),
      }
      return spawned
    },
  }

  const ctx = {
    get(name) {
      if (name === 'shell') return shell
      if (name === 'jobs') return registry
      if (name === 'agents') return { get: (id) => (id === OWNER ? agent : undefined) }
      return undefined
    },
    effect(effect) {
      const dispose = effect()
      return dispose ?? (() => {})
    },
    tools: {
      register(tool) {
        registered.push(tool)
      },
    },
    systemPrompt: {
      section(entry) {
        sections.push(entry)
      },
      getSectionOrder(name) {
        if (options.sectionOrders === 'missing') return undefined
        return name === 'TOOL_JOBS' ? 1600 : undefined
      },
    },
  }

  return {
    ctx,
    agent,
    deliveries,
    controllers,
    sections,
    commands,
    registry,
    get tool() {
      assert.equal(registered.length, 1, 'apply() must register exactly one tool')
      return registered[0]
    },
    exec: {
      agent: { session: { id: OWNER, header: { cwd: '/tmp' } } },
      signal: new AbortController().signal,
    },
    /** 追加进程输出并让注册表发一条 output 事件（watch 扫描的触发面）。 */
    append(text) {
      const job = [...jobs.values()][0]
      assert.ok(job !== undefined, 'append() needs a started job')
      job.text += text
      job.total = job.text.length
      emitOutput(job.id)
    },
    /** 注册一个"别的生产者"起的作业（后台 workflow 等），本适配器没有它的 record。 */
    addForeignJob(spec) {
      const id = `${spec.kind}-foreign-${++seq}`
      jobs.set(id, {
        id,
        kind: spec.kind,
        label: spec.label,
        owner: spec.owner ?? OWNER,
        status: 'running',
        total: 0,
        text: spec.text ?? '',
        startedAt: Date.now(),
        result: spec.result,
      })
      return id
    },
    /** 结算任意作业（含外来作业）：与注册表的 settle() 同序，先 settled 再 output。 */
    finishJob(id, status, detail) {
      finish(id, status, detail)
    },
    /** 结算当前进程：先解析 run() 的 done，再由注册表发 settled。 */
    exit(outcome) {
      assert.ok(spawned !== undefined, 'exit() needs a spawned process')
      Object.assign(spawned, outcome)
      settleSpawned()
    },
    emitOutput(id) {
      emitOutput(id)
    },
    jobId() {
      const [job] = [...jobs.values()]
      assert.ok(job !== undefined, 'jobId() needs a started job')
      return job.id
    },
    tick,
  }
}

const cases = []
const test = (name, fn) => cases.push({ name, fn })

test('start 注册到宿主 jobs，默认 success+failure 告警，idle 时 followup', async () => {
  const host = createHost()
  apply(host.ctx, {})

  const started = await host.tool.execute({ action: 'start', name: 'wake-test', command: 'sleep 8' }, host.exec)
  assert.match(started, /^started wake-test → process-1/)
  assert.deepEqual(host.controllers, ['pi-process'])
  assert.equal(host.sections[0].name, 'tool:process')
  assert.equal(host.sections[0].order, 1600)

  await tick()
  const listed = await host.tool.execute({ action: 'list' }, host.exec)
  assert.match(listed, /name: wake-test \| alerts: failure\+success \| watches: 0/)

  host.append('READY\n')
  host.exit({ status: 'completed', exitCode: 0 })
  await tick()

  assert.equal(host.deliveries.length, 1)
  assert.equal(host.deliveries[0].boundary, 'followup')
  assert.equal(host.deliveries[0].kind, 'pi-process')
  assert.equal(host.deliveries[0].summary, 'wake-test completed')
  assert.match(host.deliveries[0].text, /wake-test \(process-1\) completed — exit code: 0/)
  assert.match(host.deliveries[0].text, /Last output:\nREADY/)
})

test('alertOnSuccess: false 时成功退出不叫人', async () => {
  const host = createHost()
  apply(host.ctx, {})
  await host.tool.execute(
    { action: 'start', name: 'quiet', command: 'true', alertOnSuccess: false },
    host.exec,
  )
  await tick()
  host.exit({ status: 'completed', exitCode: 0 })
  await tick()
  assert.deepEqual(host.deliveries, [])
})

test('agent 正在跑时投 next-step（inject），不是 next-turn', async () => {
  const host = createHost({ agentStatus: 'running' })
  apply(host.ctx, {})
  await host.tool.execute({ action: 'start', name: 'wake-test2', command: 'sleep 8' }, host.exec)
  await tick()
  host.exit({ status: 'completed', exitCode: 0 })
  await tick()

  assert.equal(host.deliveries.length, 1)
  assert.equal(host.deliveries[0].boundary, 'inject')
})

test('logWatch 默认一次性，repeat: true 每行都报', async () => {
  const once = createHost()
  apply(once.ctx, {})
  await once.tool.execute(
    { action: 'start', name: 'probe', command: 'watch', logWatches: [{ pattern: 'READY' }] },
    once.exec,
  )
  await tick()
  once.append('READY first\n')
  once.append('READY second\n')
  await tick()
  assert.equal(once.deliveries.length, 1)

  const repeat = createHost()
  apply(repeat.ctx, {})
  await repeat.tool.execute(
    {
      action: 'start',
      name: 'probe',
      command: 'watch',
      alertOnSuccess: false,
      logWatches: [{ pattern: 'READY', repeat: true }],
    },
    repeat.exec,
  )
  await tick()
  repeat.append('READY first\n')
  repeat.append('READY second\n')
  await tick()
  assert.equal(repeat.deliveries.length, 2)
})

test('结算后的 output 事件不重放整圈（游标钉在终态 total）', async () => {
  const host = createHost()
  apply(host.ctx, {})
  await host.tool.execute(
    {
      action: 'start',
      name: 'probe-watch3',
      command: 'watch',
      alertOnSuccess: false,
      logWatches: [{ pattern: 'READY-MARKER', repeat: true }],
    },
    host.exec,
  )
  await tick()
  host.append('READY-MARKER\n')
  assert.equal(host.deliveries.length, 1)

  host.exit({ status: 'completed', exitCode: 0 })
  await tick()
  // 注册表结算后确实会再发一条 total 不变的 output（finish() 已按上游同序发过），
  // 这里再补一条，确保不是靠"只发一次"侥幸通过。
  host.emitOutput(host.jobId())
  await tick()

  assert.equal(host.deliveries.length, 1)
})

test('模型自己 kill 的进程不再告警（alertOnKill: true 也不叫）', async () => {
  const host = createHost()
  apply(host.ctx, {})
  await host.tool.execute(
    { action: 'start', name: 'to-kill', command: 'sleep 60', alertOnKill: true },
    host.exec,
  )
  await tick()

  const killed = await host.tool.execute({ action: 'kill', id: host.jobId() }, host.exec)
  assert.match(killed, /kill requested for to-kill \(process-1\)/)
  host.exit({ status: 'killed', signal: 'SIGTERM' })
  await tick()

  assert.deepEqual(host.deliveries, [])
})

test('write 拒绝并给出替代路径', async () => {
  const host = createHost()
  apply(host.ctx, {})
  await assert.rejects(
    host.tool.execute({ action: 'write', id: 'process-1' }, host.exec),
    /write is not supported: DSH has no live stdin pipe/,
  )
})

test('上游删掉 TOOL_JOBS 常量时挂载失败并指向根因', async () => {
  const host = createHost({ sectionOrders: 'missing' })
  assert.throws(() => apply(host.ctx, {}), /no TOOL_JOBS prompt-section order constant/)
})

test('别的生产者起的作业结算时补投通知（含返回值），并出现在 list 里', async () => {
  const host = createHost()
  apply(host.ctx, {})
  const id = host.addForeignJob({
    kind: 'background',
    label: 'nightly',
    text: 'phase 1 done\n',
    result: 'workflow "nightly" completed (2 agents).\nReturn value:\n42',
  })

  const listed = await host.tool.execute({ action: 'list' }, host.exec)
  assert.match(listed, new RegExp(`\\[running\\] background ${id} — nightly`))
  assert.match(listed, /started elsewhere in this session — no alert settings/)

  host.finishJob(id, 'completed', '2 agents')
  await tick()

  assert.equal(host.deliveries.length, 1)
  assert.equal(host.deliveries[0].boundary, 'followup')
  assert.match(host.deliveries[0].text, new RegExp(`nightly \\(${id}\\) completed — kind: background, 2 agents`))
  assert.match(host.deliveries[0].text, /phase 1 done[\s\S]*Return value:\n42/)

  const output = await host.tool.execute({ action: 'output', id }, host.exec)
  assert.match(output, /phase 1 done/)
})

test('deliverForeignJobs: false 时不替外来作业投递', async () => {
  const host = createHost()
  apply(host.ctx, { deliverForeignJobs: false })
  const id = host.addForeignJob({ kind: 'background', label: 'nightly', result: 'ignored' })
  host.finishJob(id, 'completed')
  await tick()
  assert.deepEqual(host.deliveries, [])
})

test('本工具 kill 掉的外来作业不投通知', async () => {
  const host = createHost()
  apply(host.ctx, {})
  const id = host.addForeignJob({ kind: 'background', label: 'nightly', result: 'nope' })
  const killed = await host.tool.execute({ action: 'kill', id }, host.exec)
  assert.match(killed, /kill requested for background-foreign-\d+/)
  host.finishJob(id, 'killed', 'signal: SIGTERM')
  await tick()
  assert.deepEqual(host.deliveries, [])
})

test('clear 只清自己的进程，别的工具的作业留着', async () => {
  const host = createHost()
  apply(host.ctx, {})
  const foreign = host.addForeignJob({ kind: 'background', label: 'nightly', result: 'x' })
  host.finishJob(foreign, 'completed')
  await host.tool.execute({ action: 'start', name: 'done', command: 'true' }, host.exec)
  await tick()
  host.exit({ status: 'completed', exitCode: 0 })
  await tick()

  const cleared = await host.tool.execute({ action: 'clear' }, host.exec)
  assert.match(cleared, /cleared 1 finished process\(es\)/)
  assert.match(cleared, /1 finished job\(s\) from other tools left for them to collect/)
  assert.ok(host.registry.get(foreign, OWNER))
})

let failed = 0
for (const { name, fn } of cases) {
  try {
    await fn()
    console.log(`ok   ${name}`)
  } catch (error) {
    failed += 1
    console.error(`FAIL ${name}`)
    console.error(error)
  }
}

console.log(`\n${cases.length - failed}/${cases.length} passed`)
if (failed > 0) process.exitCode = 1
