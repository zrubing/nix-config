/**
 * prompt-suppress: 按名字清空 prompt 段与 runtime context 条目（agent scope）。
 *
 * ## 解决什么问题
 *
 * `dsh-harness-dev-context` 在 host 平面挂载，于是**每一份 preset** 的会话都会拿到
 * 四条只对"改 DSH 自己"有用的贡献：
 *
 *   section  `harness:source`    "The runtime context names the DeepSeek Harness
 *                                 implementation checkout. …"（order 10000）
 *   section  `app:web-surface`   "You are interacting with the user through the
 *                                 DeepSeek Harness Web GUI …"（order 10100）
 *   context  `harness:source`    "Current DeepSeek Harness implementation checkout: …"
 *   context  `app:web-surface`   "Current DeepSeek Harness Web GUI URL: …"
 *
 * 这些对 `cordis` 这类"帮用户定制 DSH 本体"的 preset 是必要事实；对 `my-standard`
 * 这种在用户仓库里干活的 preset 只是噪音（还带品牌词）。该包没有任何 Config，
 * host 行也不能按 preset 判断，所以只能在需要的 preset 里**按名字覆盖**。
 *
 * ## 为什么是覆盖而不是改文本
 *
 * prompt 注册表按名字合并各层，近作用域的条目整条顶掉全局同名的（`dsh-persona`
 * 顶掉部署 persona 依赖同一机制）。空文本在渲染时被丢弃：
 *
 *   - section  → `renderPrompt` 的 `filter(text => text.length > 0)`
 *   - context  → `renderContextSections` 的同一条过滤
 *
 * 所以"覆盖成空串"= 该贡献消失，且**不依赖任何字面量匹配** —— 上游改措辞、加句子
 * 都不影响；反过来，如果上游删掉/改名了某个段，本插件配置里那一条就成了空转，
 * 但不撒谎、也不误伤别的内容。
 *
 * 只能在 **agent scope**（preset 的 plugins 里）挂：host 平面的全局层已经有同名条目，
 * 同一层重复注册会被注册表拒绝。
 *
 * ## 为什么 order 要写死映射
 *
 * 覆盖时整条 entry 被替换，order 也换成我们给的。名字（`harness:source`）与常量名
 * （`HARNESS_SOURCE`）不是一回事，`getSectionOrder` 只接受常量名，所以这里维护一张
 * 小映射；配置里出现不认识的名字直接抛错（fail loud），而不是猜一个 order 排错位置。
 */

import z from '@deepseek-ai/schemastery'

export const name = 'prompt-suppress'

/** prompt 注册表；本插件只注册覆盖条目。 */
export const inject = ['systemPrompt']

/** 已知段名 → `getSectionOrder` 的常量名。新增名字必须同时补这张表。 */
const SECTION_ORDER = {
  'harness:identity': 'HARNESS_IDENTITY',
  'harness:source': 'HARNESS_SOURCE',
  'app:web-surface': 'WEB_SURFACE',
}

/** 已知 context 名 → `getContextOrder` 的常量名。 */
const CONTEXT_ORDER = {
  'harness:source': 'HARNESS_SOURCE',
  'app:web-surface': 'WEB_SURFACE',
}

export const Config = z.object({
  /**
   * 段名 → 覆盖文本。空串表示该段不产生内容；缺省的名字一律不动。
   * 同一个名字若是 section 和 context 都存在（例如 `harness:source`），两边一起覆盖。
   */
  text: z.dict(z.string()).default({}),
})

export function apply(ctx, config = {}) {
  const overrides = config.text ?? {}
  for (const [name, text] of Object.entries(overrides)) {
    const sectionOrder = SECTION_ORDER[name]
    const contextOrder = CONTEXT_ORDER[name]
    if (sectionOrder === undefined && contextOrder === undefined) {
      throw new Error(
        `prompt-suppress: unknown prompt contribution "${name}"; add it to SECTION_ORDER / CONTEXT_ORDER with its order constant`,
      )
    }
    if (sectionOrder !== undefined) {
      ctx.systemPrompt.section({
        name,
        order: ctx.systemPrompt.getSectionOrder(sectionOrder),
        text,
      })
    }
    if (contextOrder !== undefined) {
      ctx.systemPrompt.context({
        name,
        order: ctx.systemPrompt.getContextOrder(contextOrder),
        text,
      })
    }
  }
}
