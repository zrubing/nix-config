// 回归测试：SP 路径随 dsh 版本变化需更新（nix store hash）。用法：node test.mjs
import { renderPrompt } from '/nix/store/9b4p33h3xrjvfz7rabgr71jfaa3is0lc-dsh-0.1.1-rc.2/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-system-prompt/lib/index.js';

// 模拟 apipost get_target_detail 描述进入 tools:sdk section 后的 assembly
const mkAssembly = () => ({
  sections: [
    { name: 'harness:identity', text: 'You are an AI agent powered by DeepSeek Harness. model={{model}} cwd={{cwd}}' },
    { name: 'tools:sdk', text: 'apipost.get_target_detail("接口参数 > 目录级参数 > 项目全局参数。接口中可以引用环境变量，语法为双大括号包裹变量名，如：{{paramName}}")' },
  ],
  contexts: [],
  tools: [{ name: 'mcp__apipost__get_target_detail', description: '引用环境变量，如：{{paramName}}', parameters: { type: 'object' } }],
  variables: { model: 'deepseek-v4-pro', cwd: '/home/jojo' },
});

// 1) 复现：未清洗 → 应 throw
try {
  renderPrompt(mkAssembly());
  console.log('UNEXPECTED: raw assembly rendered without error');
} catch (e) {
  console.log('REPRODUCED:', e.message.slice(0, 90));
}

// 2) 清洗逻辑（与插件 index.js 相同）
const known = new Set(['model', 'cwd']);
const scrub = (text) => text.replace(/\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}/g, (whole, v) =>
  known.has(v) ? whole : `\uFF5B\uFF5B${v}\uFF5D\uFF5D`);
const a = mkAssembly();
for (const s of a.sections) if (typeof s.text === 'string' && s.text.includes('{{')) s.text = scrub(s.text);

// 3) 清洗后渲染：应通过，且 {{model}}/{{cwd}} 被插值、{{paramName}} 全角保留
const out = renderPrompt(a);
console.log('SANITIZED_RENDER_OK');
console.log('interpolated model:', out.includes('model=deepseek-v4-pro'));
console.log('interpolated cwd:', out.includes('cwd=/home/jojo'));
console.log('neutralized paramName kept readable:', out.includes('\uFF5B\uFF5BparamName\uFF5D\uFF5D'));
console.log('no ascii brace pairs left in sdk section:', !/tools:sdk/.test(out.match(/tools:sdk[^\n]*\n[^\n]*/)?.[0] ?? '') || !out.split('---').some(seg => seg.includes('tools:sdk') && /\{\{[A-Za-z_]/.test(seg)));
