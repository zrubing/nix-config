// 回归测试：观测/反思游标必须在压缩重写 surface 之后继续推进；
// recall 必须从全量事件日志取数、`#N` 恒等于事件 seq、记忆 id 能回放 source 正文。
// 用法：先 `bash scripts/build.sh`（生成 lib/core/*.js），再 node 本文件。
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const home = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-blackhole-test-"));
process.env.DSH_HOME = home;
fs.mkdirSync(path.join(home, "blackhole"), { recursive: true });
const configPath = path.join(home, "blackhole", "config.json");
const baseConfig = {
  memory: true,
  compaction: "auto",
  sessionFallback: false,
  model: { provider: "test", id: "test-model" },
  observeAfterTokens: 1,
  reflectAfterTokens: 1,
};
fs.writeFileSync(configPath, JSON.stringify(baseConfig, null, 2));

const { runPipeline, flushAndRun } = await import("./lib/om.js");
const { loadLedger, ledgerPath } = await import("./lib/om-store.js");
const { recallExecute } = await import("./lib/recall.js").catch(() => {
  console.error("lib/core/*.js 缺失：先跑 bash scripts/build.sh（需要 esbuild 与 pi-blackhole 源码）");
  process.exit(1);
});

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

// ── 5) 观察门控：未攒够 observeAfterTokens 不打模型，攒够后只打一次 ─────────────
// 与 pi 的 anyStageDue 对齐。门控只看 surface 上未观察原文的 token，不看轮数。
const gateId = "session-gate-test";
fs.writeFileSync(configPath, JSON.stringify({ ...baseConfig, observeAfterTokens: 100000, reflectAfterTokens: 100000 }, null, 2));
const gateAgent = makeAgent(gateId, [{ seq: 1, role: "user", text: "短消息" }]);
const callsBefore = calls;
await runPipeline(gateAgent, ctx);
assert.equal(calls, callsBefore, "below threshold: no worker call");
assert.equal(loadLedger(gateId).cursors.observerSeq, undefined, "below threshold: cursor untouched");

gateAgent.append({ seq: 2, role: "user", text: "x".repeat(500000) }); // ~125k token
await runPipeline(gateAgent, ctx);
assert.equal(calls, callsBefore + 1, "above threshold: exactly one observer call");
assert.equal(loadLedger(gateId).cursors.observerSeq, 2, "above threshold: cursor advanced");
// 门控之外的尾部：再跑一轮没有新内容，不能再打模型。
await runPipeline(gateAgent, ctx);
assert.equal(calls, callsBefore + 1, "no new material: no extra call");
console.log("ok 5: 观察按 token 门控（<阈值不调模型，攒够只调一次）");

// ── 6) recall 从事件日志建视图：压缩遮蔽的条目仍可搜到，#N 恒等于 seq ──────────
// deriveMessages() 只含 live surface；recall 改读 snapshotEvents()，所以老条目
// 不会因为一次 compaction replace 从搜索里消失，且 #N 就是该事件的 seq。
const recallId = "session-recall-test";
const longText = "长内容开头 NEEDLE " + "x".repeat(400) + " 结尾标记";
const recallAgent = {
  id: recallId,
  session: {
    snapshotEvents: () => [
      { seq: 8, message: { role: "user", content: [{ type: "text", text: longText }] } },
      { seq: 9, message: { role: "assistant", content: [{ type: "tool-call", id: "c1", name: "write", arguments: JSON.stringify({ command: "create", file_path: "src/a.ts", content: "alpha\nNEEDLE line\nomega" }) }] } },
      { seq: 10, message: { role: "tool", toolCallId: "c1", isError: false, content: [{ type: "text", text: "tool output NEEDLE" }] } },
      { seq: 11, message: { role: "assistant", content: [
        { type: "tool-call", id: "c2", name: "write", arguments: JSON.stringify({ file_path: "src/b.ts", content: "b" }) },
        { type: "tool-call", id: "c3", name: "write", arguments: JSON.stringify({ file_path: "src/c.ts", content: "c" }) },
      ] } },
      { seq: 12, message: { role: "assistant", content: [{ type: "tool-call", id: "c4", name: "edit", arguments: JSON.stringify({ file_path: "src/d.ts", old_string: "OLDTOKEN", new_string: "NEWTOKEN" }) }] } },
      { seq: 100, message: { role: "user", content: [{ type: "text", text: "<compacted-summary>checkpoint</compacted-summary>" }] } },
    ],
    deriveEventMessage: (event) => event.message ?? null,
  },
};
const recall = (args) => recallExecute(args, { agent: recallAgent });

const searchOut = await recall({ query: "NEEDLE" });
assert.match(searchOut, /#8/, "search reaches an entry the live surface no longer contains");
assert.match(searchOut, /#10/, "tool results are searchable (role tool -> toolResult)");

const expanded = await recall({ query: "#8" });
assert.ok(expanded.includes(longText), "expand returns full content, not the clipped summary");

const drill = await recall({ query: "#9:src/a.ts:1:1" });
assert.match(drill, /NEEDLE line/, "drill-down resolves by seq");
assert.match(drill, /lines 2-2/, "drill-down honors :offset:limit");

const bodyText = await recall({ query: "#8:text" });
assert.ok(bodyText.includes(longText), "#N:text pages the message body");

const ambiguousDrill = await recall({ query: "#11:src/" });
assert.match(ambiguousDrill, /2 file operations matching/, "ambiguous path lists candidates");
assert.match(ambiguousDrill, /#11:src\/b\.ts/, "candidate list names each file");

const merged = await recall({ query: "NEEDLE", expand: [100] });
assert.match(merged, /\+ 1 expanded/, "query + expand merges non-matching entries");
assert.match(merged, /#100/, "merged expand is reachable by seq");

const editSearch = await recall({ query: "OLDTOKEN", mode: "file" });
assert.match(editSearch, /#12/, "edit diffs are indexed (old_string/new_string -> oldText/newText)");

const editDrill = await recall({ query: "#12:src/d.ts" });
assert.match(editDrill, /--- old ---\nOLDTOKEN/, "drill renders the edit body");

const touchedOut = await recall({ mode: "touched" });
assert.match(touchedOut, /files touched/, "touched mode uses pi's header");
assert.match(touchedOut, /#9 \(write\)/, "touched mode names the tool per entry");

const recent = await recall({});
assert.match(recent, /#100/, "no query lists the most recent entries");
console.log("ok 6: recall 读全量事件日志，#N = seq，工具结果可搜");

// ── 7) 记忆 id 回放：sourceEntryIds 是 seq，能还原成原文条目 ──────────────────
const memId = "abcdefabcdef";
fs.writeFileSync(ledgerPath(recallId), JSON.stringify({
  version: 1,
  observations: [{
    id: memId, timestamp: "2026-11-05 20:00", relevance: "high",
    content: "用户要求对齐 recall 行为", source: "t",
    sourceEntryIds: ["8"], status: "active",
  }],
  reflections: [],
  cursors: {},
  cooldowns: {},
}, null, 2));
const memOut = await recall({ query: memId });
assert.match(memOut, /#8 \[user\]/, "memory recall renders the source entry by seq");
assert.ok(memOut.includes("长内容开头"), "memory recall returns source content, not just the id");
console.log("ok 7: 记忆 id 回放带出 source 原文");

console.log("\nall cursor regressions pass (DSH_HOME=" + home + ")");
