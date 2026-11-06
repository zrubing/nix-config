// dsh Message[] -> pi-blackhole Message[] adapter.
//
// pi-blackhole's compile() and recall engine operate on pi's Message shape
// (roles user / assistant / toolResult / bashExecution; content blocks text /
// thinking / toolCall / image). dsh's Session yields the dsh Message shape
// (roles system / user / assistant / tool; blocks text / reasoning / image /
// tool-call / tool-result). This adapter is the only translation layer —
// everything else calls the upstream package unchanged.
//
// Two views are exposed:
//   - toPiMessages(deriveMessages())      live surface, used by compaction
//     (only the messages that are still in context belong in a summary).
//   - toPiMessagesFromEvents(snapshotEvents())  full durable history, used by
//     recall. The event log is append-only and never rewrites seqs, so a
//     compaction `replace` cannot hide earlier material from search, and the
//     seq doubles as the stable `#N` handle.

/** dsh tool-call id -> tool name, so tool-result messages can be named. */
function buildCallNames(dshMessages) {
  const names = new Map();
  for (const msg of dshMessages) {
    if (msg?.role !== "assistant") continue;
    for (const part of msg.content || []) {
      if (part?.type === "tool-call") names.set(part.id, part.name);
    }
  }
  return names;
}

/**
 * Rename dsh edit-diff arguments to pi's names.
 *
 * pi-blackhole's search index, file indicators and drill-down heuristics read
 * `oldText` / `newText`; dsh's edit tool uses `old_string` / `new_string`.
 * Without this, edit diffs are invisible to `mode:file` search and to
 * file-match aggregation.
 */
function normalizeToolArgs(args) {
  if (!args || typeof args !== "object") return args;
  if (typeof args.old_string === "string" && args.oldText === undefined) {
    args.oldText = args.old_string;
    delete args.old_string;
  }
  if (typeof args.new_string === "string" && args.newText === undefined) {
    args.newText = args.new_string;
    delete args.new_string;
  }
  return args;
}

/** Map dsh content blocks -> pi content blocks (text/thinking/toolCall/image). */
function toPiBlocks(blocks) {
  const out = [];
  for (const part of blocks || []) {
    if (!part || typeof part !== "object") continue;
    if (part.type === "text") out.push({ type: "text", text: part.text || "" });
    else if (part.type === "reasoning") out.push({ type: "thinking", thinking: part.text || "", redacted: part.redacted ?? false });
    else if (part.type === "tool-call") {
      let args = {};
      try { args = JSON.parse(part.arguments || "{}") || {}; } catch { args = {}; }
      out.push({ type: "toolCall", name: part.name, arguments: normalizeToolArgs(args) });
    } else if (part.type === "image") out.push({ type: "image", mimeType: part.attachment?.mediaType ?? "image/png" });
  }
  return out;
}

/** A dsh user message that carries only tool-result blocks becomes pi toolResult messages. */
function isToolResultOnly(blocks) {
  const nonToolResults = (blocks || []).filter((p) => p?.type !== "tool-result");
  const hasToolResult = (blocks || []).some((p) => p?.type === "tool-result");
  return hasToolResult && nonToolResults.length === 0;
}

/**
 * Convert one dsh message to zero or more pi messages.
 * Tool results reach dsh as their own `tool/result` events (role "tool");
 * older/foreign logs may instead embed them in a user message, so both shapes
 * are handled.
 */
function convertOne(msg, callNames) {
  if (!msg || msg.role === "system" || msg.role === "developer") return [];

  if (msg.role === "assistant") {
    return [{ role: "assistant", content: toPiBlocks(msg.content) }];
  }

  if (msg.role === "tool") {
    return [{
      role: "toolResult",
      toolName: callNames.get(msg.toolCallId) || "tool",
      content: toPiBlocks(msg.content),
      isError: !!msg.isError,
    }];
  }

  if (msg.role !== "user") return [];

  const blocks = msg.content || [];
  if (isToolResultOnly(blocks)) {
    return blocks
      .filter((part) => part?.type === "tool-result")
      .map((part) => ({
        role: "toolResult",
        toolName: callNames.get(part.toolCallId) || "tool",
        content: toPiBlocks(part.content),
        isError: !!part.isError,
      }));
  }

  const content = toPiBlocks(blocks.filter((p) => p?.type !== "tool-result"));
  if (content.length > 0) return [{ role: "user", content }];
  return [{ role: "user", content: [{ type: "text", text: "" }] }];
}

/**
 * Convert a dsh Message[] (as returned by Session.deriveMessages()) into pi
 * Message[] suitable for pi-blackhole's compile().
 */
export function toPiMessages(dshMessages) {
  const callNames = buildCallNames(dshMessages);
  return (dshMessages || []).flatMap((msg) => convertOne(msg, callNames));
}

/**
 * Convert the FULL session event log into pi messages, one row per message,
 * each carrying the event seq it came from.
 *
 * The seq is the durable identity: it is assigned once, survives compaction
 * `replace` (which only removes nodes from the surface, never rewrites the
 * log), and is what the observational-memory ledger records as
 * `sourceEntryIds`. Callers therefore use `seq` as the model-facing `#N`
 * handle instead of an array position, which compaction would shift.
 *
 * Rewritten messages stay as separate rows, exactly like pi's own session
 * file: a pruned tool result does not erase the original payload, which is
 * what recall exists to recover.
 *
 * @returns {{ seq: number, message: object }[]} rows in log order.
 */
export function toPiMessagesFromEvents(session) {
  const events = session?.snapshotEvents?.() ?? [];
  if (events.length === 0) return [];

  const rows = [];
  for (const event of events) {
    const msg = session.deriveEventMessage?.(event);
    if (msg) rows.push({ seq: event.seq, msg });
  }

  const callNames = buildCallNames(rows.map((row) => row.msg));
  return rows.flatMap(({ seq, msg }) =>
    convertOne(msg, callNames).map((message) => ({ seq, message })),
  );
}
