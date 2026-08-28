// dsh Message[] -> pi-blackhole Message[] adapter.
//
// pi-blackhole's compile() and recall engine operate on pi's Message shape
// (roles user / assistant / toolResult / bashExecution; content blocks text /
// thinking / toolCall / image). dsh's Session.deriveMessages() yields the dsh
// Message shape (roles system / user / assistant; blocks text / reasoning /
// image / tool-call / tool-result). This adapter is the only translation
// layer — everything else calls the upstream package unchanged.

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
      out.push({ type: "toolCall", name: part.name, arguments: args });
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
 * Convert a dsh Message[] (as returned by Session.deriveMessages()) into pi
 * Message[] suitable for pi-blackhole's compile() or recall search engine.
 */
export function toPiMessages(dshMessages) {
  const callNames = buildCallNames(dshMessages);
  const out = [];
  for (const msg of dshMessages || []) {
    if (!msg || msg.role === "system") continue;
    if (msg.role === "assistant") {
      out.push({ role: "assistant", content: toPiBlocks(msg.content) });
      continue;
    }
    if (msg.role !== "user") continue;

    const blocks = msg.content || [];
    if (isToolResultOnly(blocks)) {
      for (const part of blocks) {
        if (part?.type !== "tool-result") continue;
        const name = callNames.get(part.toolCallId) || "tool";
        out.push({
          role: "toolResult",
          toolName: name,
          content: toPiBlocks(part.content),
          isError: !!part.isError,
        });
      }
      continue;
    }

    const content = toPiBlocks(blocks.filter((p) => p?.type !== "tool-result"));
    if (content.length > 0) out.push({ role: "user", content });
    else out.push({ role: "user", content: [{ type: "text", text: "" }] });
  }
  return out;
}

/** True when a dsh message is a plain user message (skip tool-results). */
export function isPlainUser(msg) {
  return msg?.role === "user" && !(msg.content || []).some((p) => p?.type === "tool-result");
}
