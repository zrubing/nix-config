// 回归测试：观测/反思游标必须在压缩重写 surface 之后继续推进。
// 用法：node modules/home/dsh/plugins/dsh-blackhole/test.mjs
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const home = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-blackhole-test-"));
process.env.DSH_HOME = home;
fs.mkdirSync(path.join(home, "blackhole"), { recursive: true });
fs.writeFileSync(path.join(home, "blackhole", "config.json"), JSON.stringify({
  memory: true,
  compaction: "auto",
  sessionFallback: false,
  model: { provider: "test", id: "test-model" },
  observeAfterTokens: 1,
  reflectAfterTokens: 1,
}, null, 2));

const { runPipeline, flushAndRun } = await import("./lib/om.js");
const { loadLedger, ledgerPath } = await import("./lib/om-store.js");

/** A stand-in for one dsh surface: nodes carry durable seqs, messages derive 1:1. */
function makeAgent(id, initialNodes) {
  let nodes = [...initialNodes];
  return {
    id,
    session: {
      surface: { get nodes() { return nodes.map((n) => n.seq); } },
      deriveMessages: () => nodes.map((n) => ({ role: n.role, content: [{ type: "text", text: n.text }] })),
    },
    /** Simulate a compaction replace: shadowed seqs collapse into one checkpoint. */
    compact(removeSeqs, checkpointSeq) {
      const kept = nodes.filter((n) => !removeSeqs.includes(n.seq));
      nodes = [{ seq: checkpointSeq, role: "user", text: "<compacted-summary>checkpoint</compacted-summary>" }, ...kept];
    },
    append(node) { nodes = [...nodes, node]; },
  };
}

let calls = 0;
const ctx = {
  get: () => undefined,
  llm: {
    // One freshly minted observation/reflection per call, so counts are assertable.
    async *stream() {
      calls += 1;
      const reply = JSON.stringify([{ content: `memory item ${calls}`, relevance: "low", source: "test" }]);
      yield { type: "block-start", index: 0, blockType: "text" };
      yield { type: "text-delta", index: 0, text: reply };
      yield { type: "block-end", index: 0, block: { type: "text", text: reply } };
      yield { type: "finish" };
    },
  },
};

// ── 1) 首轮观察：覆盖整个 surface，游标落到最后一个 seq ──────────────────────
const agent = makeAgent("session-cursor-test", [
  { seq: 1, role: "user", text: "把阈值改成 0.4" },
  { seq: 2, role: "assistant", text: "改好了" },
  { seq: 3, role: "user", text: "再跑一遍测试" },
  { seq: 4, role: "assistant", text: "测试通过" },
  { seq: 5, role: "user", text: "提交吧" },
  { seq: 6, role: "assistant", text: "已提交" },
]);
await runPipeline(agent, ctx);
let ledger = loadLedger(agent.id);
assert.equal(ledger.observations.length, 1, "first observation recorded");
assert.equal(ledger.cursors.observerSeq, 6, "observer cursor advanced to the newest seq");
console.log("ok 1: 首轮观察覆盖到 seq 6");

// ── 2) 压缩把 surface 从 6 项缩到 2 项：游标必须继续推进 ─────────────────────
// 旧的下标游标（=5）在这里会永久卡住：压缩后数组只剩 2 项，index > 5 永远为空。
agent.compact([1, 2, 3, 4, 5], 100);
await runPipeline(agent, ctx);
ledger = loadLedger(agent.id);
assert.equal(ledger.observations.length, 2, "checkpoint observed after compaction");
assert.equal(ledger.cursors.observerSeq, 100, "cursor moved to the checkpoint seq");
agent.append({ seq: 101, role: "user", text: "继续" });
await runPipeline(agent, ctx);
ledger = loadLedger(agent.id);
assert.equal(ledger.observations.length, 3, "new material after the checkpoint observed");
assert.equal(ledger.cursors.observerSeq, 101, "cursor kept advancing after compaction");
console.log("ok 2: 压缩后 checkpoint 与新消息都被观察（seq 100 → 101）");

// ── 3) flush 不再把游标清回起点 ─────────────────────────────────────────────
const beforeFlush = loadLedger(agent.id).cursors.observerSeq;
await flushAndRun(agent, ctx);
assert.equal(loadLedger(agent.id).cursors.observerSeq, beforeFlush, "flush keeps the observer cursor");
console.log("ok 3: /blackhole flush 后游标保持", beforeFlush);

// ── 4) reflector：dropper 丢掉旧观察后，新观察仍会被反思 ──────────────────────
// 旧的下标游标建在"过滤掉 dropped"的数组上，A 被丢弃后位置前移，紧跟的新观察
// 会被 slice(cursor+1) 永久跳过。
const id = "session-reflector-test";
fs.writeFileSync(ledgerPath(id), JSON.stringify({
  version: 1,
  observations: [
    { id: "aaaaaaaaaaaa", timestamp: "2026-09-24 17:00", relevance: "low", content: "A", source: "t", sourceEntryIds: [], status: "dropped" },
    { id: "bbbbbbbbbbbb", timestamp: "2026-09-24 17:01", relevance: "low", content: "B", source: "t", sourceEntryIds: [], status: "active" },
    { id: "cccccccccccc", timestamp: "2026-09-24 17:02", relevance: "low", content: "C", source: "t", sourceEntryIds: [], status: "active" },
    { id: "dddddddddddd", timestamp: "2026-09-24 17:03", relevance: "low", content: "D", source: "t", sourceEntryIds: [], status: "active" },
  ],
  reflections: [],
  cursors: { observerSeq: 0, reflectorId: "dddddddddddd" },
  cooldowns: {},
}, null, 2));
// 空 surface：本轮 observer 无新内容可看（不新增 observation），只测 reflector。
const reflectorAgent = makeAgent(id, []);
const reflectorLedger = loadLedger(id);
reflectorLedger.observations.push({
  id: "eeeeeeeeeeee", timestamp: "2026-09-24 17:04", relevance: "low", content: "E", source: "t", sourceEntryIds: [], status: "active",
});
fs.writeFileSync(ledgerPath(id), JSON.stringify(reflectorLedger, null, 2));
await runPipeline(reflectorAgent, ctx);
const after = loadLedger(id);
assert.equal(after.reflections.length, 1, "new observation after a drop is still reflected");
assert.equal(after.cursors.reflectorId, "eeeeeeeeeeee", "reflector cursor is the newest reflected observation id");
console.log("ok 4: dropped 前移后新观察仍被反思，游标 = eeeeeeeeeeee");

console.log("\nall cursor regressions pass (DSH_HOME=" + home + ")");
