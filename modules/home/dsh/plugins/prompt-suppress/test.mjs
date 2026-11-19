/**
 * 回归测试：prompt-suppress 的注册面与 fail-loud 行为。
 *
 * 用法：node test.mjs（不依赖任何 store 路径，直接导入同目录的 index.js）。
 *
 * 覆盖三件事：
 *   1. 配置里的每个名字都注册成 section + context（同名双形态），order 取自常量；
 *   2. 空文本原样注册（渲染层的空文本过滤负责"消失"，插件不做判断）；
 *   3. 表外名字立刻抛错，而不是猜一个 order 把段排错位置。
 */
import { apply } from './index.js'

const calls = []
const ctx = {
  systemPrompt: {
    section: (entry) => calls.push(['section', entry]),
    context: (entry) => calls.push(['context', entry]),
    getSectionOrder: (constant) => {
      const table = { HARNESS_IDENTITY: -1000, HARNESS_SOURCE: 10000, WEB_SURFACE: 10100 }
      if (!(constant in table)) throw new Error(`unknown section order constant: ${constant}`)
      return table[constant]
    },
    getContextOrder: (constant) => {
      const table = { HARNESS_SOURCE: 200, WEB_SURFACE: 210 }
      if (!(constant in table)) throw new Error(`unknown context order constant: ${constant}`)
      return table[constant]
    },
  },
}

apply(ctx, {
  text: {
    'harness:identity': '',
    'harness:source': '',
    'app:web-surface': '',
  },
})

const expected = [
  ['section', { name: 'harness:identity', order: -1000, text: '' }],
  ['section', { name: 'harness:source', order: 10000, text: '' }],
  ['context', { name: 'harness:source', order: 200, text: '' }],
  ['section', { name: 'app:web-surface', order: 10100, text: '' }],
  ['context', { name: 'app:web-surface', order: 210, text: '' }],
]

console.log('registered:', calls.length, 'entries')
for (const [kind, entry] of calls) console.log(` ${kind.padEnd(7)} ${entry.name} @ ${entry.order} text=${JSON.stringify(entry.text)}`)
console.log('matches expectation:', JSON.stringify(calls) === JSON.stringify(expected))

let failed = false
try {
  apply(ctx, { text: { 'no:such-section': '' } })
} catch (error) {
  failed = error.message.includes('unknown prompt contribution')
}
console.log('unknown name fails loud:', failed)

// 非空覆盖同样落到同名段上（换文案不用改代码）
calls.length = 0
apply(ctx, { text: { 'harness:source': 'The runtime context names the implementation checkout.' } })
console.log('override text honored:', JSON.stringify(calls.map(([, e]) => e.text)))
