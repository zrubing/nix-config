#!/usr/bin/env node
// dsh-routing-suite ↔ dsh 0.2.2 兼容层（router-bootstrap 的构建期改写）。
//
// TL;DR: 上游快照按锚点改写成 0.2.2 形态——首轮工具门控移到 agent/created 的
// restrict，Bootstrap 引导并入工具结果；不再用 waterfall.tools 与 inbox 注入。
// 锚点对不上就构建失败，不产出半兼容 preset。
//
// ## 为什么需要它
//
// `modules/home/dsh/agent-presets/{router-standard,my-router-standard}/` 是上游
// `yjh051108/dsh-routing-suite`（preset/router-standard）的原样快照，最后改动
// 2026-09-02，对应 dsh 0.2.x 早期。dsh 0.2.2 改掉了两条本预设依赖的契约：
//
//   1. `system-prompt/assemble` 的载荷从 PromptAssembly 收窄成 PromptPresentation
//      （只剩 sections/contexts/variables）。工具声明由 provider 拥有，registry 在
//      waterfall 之后**无条件回填**全量 tools。因此 `assembled.tools.filter(...)`
//      在首轮抛 `TypeError: Cannot read properties of undefined (reading 'filter')`，
//      turn 直接以 error 结束（实测：session 日志 turn/end reason=error）。
//   2. 在工具执行体内（或同一 step 内）向 `inbox.append('next-step', …)` 入队会与
//      循环的 inbox 串行区互锁：工具结果永不落盘，turn 永久停在 tool/call。
//
// ## 改写内容（每条锚点必须唯一命中，否则构建失败）
//
//   1. `agent/created` 冷门控 —— 在 agent 组合完成、任何 step 解析工具之前，对继承面
//      下一道 deny：除 phase_begin 与 meta 工具外全部隐藏。phase_begin 的
//      applyStageRestrict(0) 经 sharedLift 释放它并按阶段放行。已 guided 的会话
//      （resume）不重下冷门控。
//   2. 首轮 waterfall 分支不再改 tools（0.2.2 里该字段不存在）。
//   3. `available` 改读 registry 的 knownToolNames（原读 assembled.tools）。
//   4. 两处 Bootstrap 引导不再 append 到 next-step，改为并入 phase_begin 的工具结果
//      文本——模型在同一步看到同一段引导，语义等价且不触碰 inbox。
//
// ## 用法
//
//   node dsh-0.2.2-bootstrap.mjs <in.mjs> <out.mjs>
//
// 上游一旦改动这些锚点，脚本以非零码退出并打印命中的告警——**不允许**静默产出
// 半兼容的 preset（那会在运行期表现为 turn error 或永久挂起）。
import { readFileSync, writeFileSync } from 'node:fs'

/** 冷门控监听器：插在 apply() 的花括号之后。 */
const COLD_RESTRICT = `export function apply(ctx, config) {
  // ── dsh 0.2.2 兼容层：首轮工具门控 ──────────────────────────────────────
  // TL;DR: 0.2.2 没有 waterfall.tools，首轮门控改为 agent/created 上下一道 restrict
  // （只留 phase_begin + meta），phase_begin 再按阶段换 allow。
  // 0.2.2 起 system-prompt/assemble 的载荷是 PromptPresentation（只有
  // sections/contexts/variables），工具声明由 provider 拥有并在 waterfall 之后统一
  // 回填。旧写法 assembled.tools.filter(...) 因此抛 TypeError，turn 直接 error。
  // 替代机制：在 agent 组合完成、任何 step 解析工具之前（agent/created）对继承面
  // 下一道 deny——除 phase_begin 与 meta 工具外全部隐藏；phase_begin 触发的
  // applyStageRestrict(0) 会经 sharedLift 释放它并按阶段放行。已 guided 的会话
  // （resume）不重下冷门控，否则会把当前阶段工具一起藏掉。
  try {
    ctx.on('agent/created', ({ agent } = {}) => {
      try {
        const sid = agent?.session?.id
        if (sid === undefined) return
        if (ensureStage()[sid]?.guided === true) return
        const ts = agent?.ctx?.get?.('tools')
        if (!ts || typeof ts.restrict !== 'function' || typeof ts.view !== 'function') return
        const inherited = [...(ts.view(agent)?.restrictableNames ?? [])]
          .filter((n) => n !== 'phase_begin' && !META_ALL.includes(n))
        if (inherited.length === 0) return
        const disposer = ts.restrict({ deny: inherited })
        if (disposer) sharedLift.set(sid, disposer)
      } catch (e) { console.error('[router-bootstrap] cold restrict failed:', e) }
    })
  } catch (e) { console.error('[router-bootstrap] agent/created hook failed:', e) }`

/** 改写规则表：每条 find 必须恰好出现一次。 */
const EDITS = [
  {
    name: 'apply() 冷门控',
    find: 'export function apply(ctx, config) {',
    replace: COLD_RESTRICT,
  },
  {
    name: '首轮 waterfall 分支（去掉 tools 字段）',
    find: `    if (!promoted) {
      // 首轮：无 restrict + 工具面只留 phase_begin（纯 RL 条件 = 稳定 we）
      return { ...assembled, sections: baseSections, contexts: [], tools: assembled.tools.filter((tool) => tool.name === 'phase_begin') }
    }`,
    replace: `    if (!promoted) {
      // 首轮：纯 RL 句（工具门控由 apply() 的 agent/created 冷 restrict 负责，
      // waterfall 在 0.2.2 里不再拥有 tools 字段）。
      return { ...assembled, sections: baseSections, contexts: [] }
    }`,
  },
  {
    name: 'run_code 探测（改读 registry）',
    find: '    const available = new Set(assembled.tools.map((tool) => tool.name))',
    replace: '    const available = knownToolNames(toolsSvc, agent) // 0.2.2：waterfall 无 tools，改读 registry',
  },
  {
    name: 'fresh bootstrap 引导（并入工具结果）',
    find: `        try {
          currentAgent()?.inbox.append('next-step', {
            id: 'bootstrap-fresh-' + Date.now(),
            role: 'user',
            source: { kind: 'plugin', plugin: 'router-bootstrap' },
            content: [{ type: 'text', text: guide }],
          })
        } catch { /* skip */ }
        return 'session started (fresh-auto): phase 0 了解/对齐 unlocked — Bootstrap injected. New conversation detected; stage state reset.'`,
    replace: `        // 0.2.2 兼容：在工具体内向 next-step 入队会与循环的 inbox 串行区互锁
        // （实测 turn 永远卡在 tool/call，结果不落盘）。改为把同一段引导并入工具
        // 结果返回——模型在同一步就看到它，语义等价、且不触碰 inbox。
        return 'session started (fresh-auto): phase 0 了解/对齐 unlocked — Bootstrap injected. New conversation detected; stage state reset.\\n\\n' + guide`,
  },
  {
    name: 'bootstrap 引导（并入工具结果）',
    find: `      try {
        currentAgent()?.inbox.append('next-step', {
          id: 'bootstrap-' + Date.now(),
          role: 'user',
          source: { kind: 'plugin', plugin: 'router-bootstrap' },
          content: [{ type: 'text', text: guide }],
        })
      } catch { /* skip */ }
      return 'session started: phase ' + existing.stage + ' (' + STAGES[existing.stage].name + ') unlocked — Bootstrap injected.'`,
    replace: `      return 'session started: phase ' + existing.stage + ' (' + STAGES[existing.stage].name + ') unlocked — Bootstrap injected.\\n\\n' + guide`,
  },
]

const [input, output] = process.argv.slice(2)
if (input === undefined || output === undefined) {
  console.error('usage: dsh-0.2.2-bootstrap.mjs <in.mjs> <out.mjs>')
  process.exit(2)
}

let source = readFileSync(input, 'utf8')
const failures = []
for (const edit of EDITS) {
  const hits = source.split(edit.find).length - 1
  if (hits !== 1) {
    failures.push(`${edit.name}: expected exactly 1 anchor, found ${hits}`)
    continue
  }
  source = source.replace(edit.find, edit.replace)
}
if (failures.length > 0) {
  console.error('dsh-0.2.2 compat: upstream anchors changed — refusing to emit a half-patched preset:')
  for (const failure of failures) console.error('  - ' + failure)
  console.error('  file: ' + input)
  process.exit(1)
}
writeFileSync(output, source, 'utf8')
