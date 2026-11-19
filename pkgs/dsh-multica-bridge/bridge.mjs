#!/usr/bin/env node
/**
 * Multica 的 DSH runtime 桥。
 *
 * ## 为什么需要它
 *
 * Multica 的 runtime 契约是「stdio 子进程 + JSONL」：daemon 会执行
 * `dsh --profile multica --probe|--list-models|--stdio`，由 dsh 进程内的
 * `@multica-ai/dsh-runtime` 插件应答。那种形态每个任务都要起一个完整的 dsh
 * （profile 组装 5s 起），并且和常驻的 `dsh-web` 是两个互不相干的进程。
 *
 * 本桥顶替 `dsh` 这个可执行文件（`MULTICA_DSH_PATH`），把同一份 JSONL 协议
 * 翻译成对**已在运行的 web host** 的 remote RPC：会话在 host 里创建、prompt、
 * 取消，事件流同样从 host 取。于是 multica 的任务会作为普通会话出现在 web UI /
 * dsh-tui-remote 里，不再有第二个 dsh 实例。
 *
 * ## 依赖的外部模块
 *
 * 不复刻 host 的 typert 客户端：直接复用 `dsh-tui-remote` 里那套 remote 模块
 * （它本来就从「连接到的那个安装」动态加载客户端），这样协议半边永远与 host 同源。
 * 路径由 wrapper 通过 DSH_TUI_REMOTE_TREE 注入。
 */
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';

const PROTOCOL_VERSION = 1;
const MAX_TOOL_OUTPUT_BYTES = 256 * 1024;
const PLUGIN_VERSION = process.env.DSH_BRIDGE_VERSION ?? '0.0.1';

const tree = process.env.DSH_TUI_REMOTE_TREE;
if (!tree) {
  process.stderr.write('dsh-multica-bridge: DSH_TUI_REMOTE_TREE is not set\n');
  process.exit(1);
}
const baseUrl = process.env.MULTICA_DSH_BRIDGE_URL ?? 'http://127.0.0.1:3080';

/** runTask 注册的取消回调；stdio 收到 cancel 帧时调用。 */
let cancelHandler = () => {};

function write(frame) {
  process.stdout.write(`${JSON.stringify(frame)}\n`);
}
function diagnostic(message) {
  process.stderr.write(`dsh-multica-bridge: ${message}\n`);
}
function protocolError(code, message) {
  write({ v: PROTOCOL_VERSION, type: 'protocol_error', code, message });
}

/** 与 multica runtime 的 truncateUtf8 同义：按字节截断且不切坏多字节字符。 */
function truncateUtf8(value, maxBytes = MAX_TOOL_OUTPUT_BYTES) {
  const bytes = Buffer.from(value);
  if (bytes.length <= maxBytes) return { value, truncated: false };
  let end = maxBytes;
  while (end > 0 && bytes[end] >= 0x80 && bytes[end] < 0xc0) end--;
  return { value: `${bytes.subarray(0, end).toString('utf8')}\n[output truncated]`, truncated: true };
}

function renderBlock(block) {
  switch (block.type) {
    case 'text':
    case 'reasoning':
      return block.text;
    case 'image':
      return `[image attachment ${block.attachment?.attachmentId ?? '?'}]`;
    case 'file':
      return `[file attachment ${block.attachment?.name ?? '?'}]`;
    case 'tool-call':
      return `[tool call ${block.name}: ${block.arguments}]`;
    default:
      return '';
  }
}

async function loadModules() {
  const [connection, session] = await Promise.all([
    import(`${tree}/lib/types/dsh-adapter/remote/connection.js`),
    import(`${tree}/lib/types/dsh-adapter/remote/session.js`),
  ]);
  const live = await import(`${tree}/lib/types/dsh-adapter/remote/live.js`);
  return { connection, session, live };
}

async function connect() {
  const { connection } = await loadModules();
  return await connection.connectRemote(baseUrl);
}

function encodeModelId(provider, model) {
  return `${encodeURIComponent(provider)}/${encodeURIComponent(model)}`;
}

async function listModels() {
  const conn = await connect();
  const catalog = await conn.catalog.read();
  const selected = catalog?.default ?? {};
  const models = [];
  for (const group of catalog?.groups ?? []) {
    for (const model of group.models ?? []) {
      const reasoning = model.reasoning;
      models.push({
        id: encodeModelId(group.id, model.id),
        label: model.name ?? model.id,
        provider: group.name ?? group.id,
        ...(selected.provider === group.id && selected.model === model.id ? { default: true } : {}),
        ...(reasoning === undefined
          ? {}
          : {
              thinking: {
                supported_levels: (reasoning.efforts ?? []).map((effort) => ({
                  value: String(effort.id),
                  label: effort.name ?? String(effort.id),
                  ...(effort.description === undefined ? {} : { description: effort.description }),
                })),
                ...(reasoning.defaultEffort === undefined
                  ? {}
                  : { default_level: String(reasoning.defaultEffort) }),
              },
            }),
      });
    }
  }
  models.sort((a, b) => a.provider.localeCompare(b.provider) || a.label.localeCompare(b.label));
  return models;
}

/**
 * multica 的 daemon 用单行 JSONL 读模型表，单帧有 ~64 KiB 上限。
 * 实测（2026-11-19，multica 0.8.2）：
 *   700 个合成模型 / 62.8 KB → 解析成功，UI 正常；
 *   800 个 / 71.8 KB      → daemon 静默丢帧，请求停在 pending，
 *                           或无缓存时报 "dsh returned an empty model catalog"。
 * dsh host 的 provider 表里有上千个模型（openrouter 一家就几百个），原样输出
 * 是 120 KB 量级，必然超限。所以这里按字节预算裁剪。
 *
 * 裁剪顺序（确定性）：
 *   1. 默认模型优先，UI 打开时选中的就是它；
 *   2. 其余按 provider 轮流各取一个 —— 保证每家都露脸，而不是按字母序把
 *      排在后面的 provider 整段丢掉；
 *   3. 累计字节超过预算即停。
 * 被裁掉的模型仍可在 UI 里手动输入 ID（picker 支持搜索/手填）。
 */
const MAX_CATALOG_BYTES = Number(
  process.env.MULTICA_DSH_BRIDGE_MAX_CATALOG_BYTES ?? 48 * 1024,
);

function frameBytes(models) {
  return Buffer.byteLength(JSON.stringify({ v: PROTOCOL_VERSION, type: 'models', models })) + 1;
}

function capCatalog(models) {
  if (frameBytes(models) <= MAX_CATALOG_BYTES) return models;

  const out = [];
  let used = 64; // 帧骨架的开销（v/type/空数组），按上限留足余量
  const push = (model) => {
    const size = Buffer.byteLength(JSON.stringify(model)) + 1;
    if (used + size > MAX_CATALOG_BYTES) return false;
    used += size;
    out.push(model);
    return true;
  };

  for (const model of models) if (model.default) push(model);

  // provider → 待选模型队列（保持 listModels 的排序）
  const queues = new Map();
  for (const model of models) {
    if (model.default) continue;
    if (!queues.has(model.provider)) queues.set(model.provider, []);
    queues.get(model.provider).push(model);
  }

  for (let round = 0; ; round++) {
    let progressed = false;
    for (const queue of queues.values()) {
      if (round >= queue.length) continue;
      push(queue[round]);
      progressed = true;
    }
    if (!progressed) break;
  }
  return out;
}

/**
 * 一个任务 = 一个 host 会话。事件来自 `session/follow` 的持久日志流；
 * 映射后的帧与 `@multica-ai/dsh-runtime` 的 observeSessionEvent 一致。
 */
async function runTask(command) {
  const { session: sessionApi, live } = await loadModules();
  const conn = await connect();
  const requestId = command.request_id;

  let sessionId = command.resume_session_id;
  let resumed = false;
  if (sessionId === undefined) {
    sessionId = await sessionApi.createRemoteSession(conn.remote, command.cwd);
  } else {
    resumed = true;
  }

  const abort = new AbortController();
  let opened = false;
  let endReason;
  let lastText = '';
  let cancelRequested = false;
  const toolNames = new Map();

  const finish = (() => {
    let resolve;
    const promise = new Promise((r) => {
      resolve = r;
    });
    return { promise, resolve };
  })();

  const stream = live.openLiveStream(conn.live, {
    name: 'session/follow',
    open: (signal) =>
      conn.remote.session.follow(
        { address: { kind: 'session', sessionId }, maxMessages: 200, assistantStream: true },
        signal,
      ),
    isSnapshot: (frame) => frame.type === 'snapshot',
    replace: () => {
      opened = true;
    },
    update: (frame) => {
      if (frame.type !== 'event') return;
      const event = frame.event;
      if (event.type === 'assistant/message') {
        const content = event.data?.message?.content ?? [];
        const text = content
          .filter((block) => block.type === 'text')
          .map((block) => block.text)
          .join('');
        if (text !== '') {
          lastText = text;
          write({ v: PROTOCOL_VERSION, type: 'text', request_id: requestId, content: text });
        }
        for (const block of content) {
          if (block.type === 'reasoning' && block.text) {
            write({ v: PROTOCOL_VERSION, type: 'thinking', request_id: requestId, content: block.text });
          }
        }
        const usage = event.data?.usage;
        if (usage !== undefined) {
          write({
            v: PROTOCOL_VERSION,
            type: 'usage',
            request_id: requestId,
            provider: event.data?.message?.source?.provider ?? '',
            model: event.data?.message?.source?.model ?? '',
            input_tokens: usage.inputTokens,
            output_tokens: usage.outputTokens,
            ...(usage.cacheReadTokens === undefined ? {} : { cache_read_tokens: usage.cacheReadTokens }),
            ...(usage.cacheWriteTokens === undefined ? {} : { cache_write_tokens: usage.cacheWriteTokens }),
            ...(usage.reasoningTokens === undefined ? {} : { reasoning_tokens: usage.reasoningTokens }),
          });
        }
        return;
      }
      if (event.type === 'tool/call') {
        const callId = String(event.data.callId);
        toolNames.set(callId, event.data.name);
        write({
          v: PROTOCOL_VERSION,
          type: 'tool_call',
          request_id: requestId,
          call_id: callId,
          name: event.data.name,
          arguments: event.data.arguments,
        });
        return;
      }
      if (event.type === 'tool/result') {
        const message = event.data.message;
        const callId = String(message.toolCallId);
        const rendered = truncateUtf8((message.content ?? []).map(renderBlock).join(''));
        write({
          v: PROTOCOL_VERSION,
          type: 'tool_result',
          request_id: requestId,
          call_id: callId,
          name: toolNames.get(callId) ?? 'unknown',
          output: rendered.value,
          is_error: message.isError === true,
          ...(rendered.truncated ? { truncated: true } : {}),
        });
        return;
      }
      if (event.type === 'turn/end') {
        endReason = event.data?.reason;
        finish.resolve('end');
      }
    },
    failed: (error) => {
      diagnostic(`follow failed: ${error instanceof Error ? error.message : String(error)}`);
      finish.resolve('lost');
    },
  });

  write({ v: PROTOCOL_VERSION, type: 'session', request_id: requestId, session_id: sessionId, resumed });

  const cancel = () => {
    if (cancelRequested) return;
    cancelRequested = true;
    conn.remote.session.cancel({ sessionId }).catch((error) => {
      diagnostic(`cancel failed: ${error instanceof Error ? error.message : String(error)}`);
    });
    finish.resolve('cancelled');
  };
  cancelHandler = cancel;

  const prompted = await conn.remote.session.prompt({
    requestId: randomUUID(),
    sessionId,
    mode: 'queue',
    content: [{ type: 'text', text: command.prompt }],
  });
  if (!prompted.ok) {
    stream.dispose();
    write({
      v: PROTOCOL_VERSION,
      type: 'result',
      request_id: requestId,
      session_id: sessionId,
      status: cancelRequested ? 'cancelled' : 'failed',
      output: lastText,
      resume_rejected: false,
      error: {
        code: resumed ? 'DSH_RESUME_REJECTED' : 'DSH_RUNTIME_ERROR',
        message: `session/prompt failed: ${prompted.error?.message ?? 'unknown error'}`,
      },
    });
    return 1;
  }

  const outcome = await finish.promise;
  stream.dispose();

  const status =
    cancelRequested || outcome === 'cancelled'
      ? 'cancelled'
      : endReason?.kind === 'completed' || endReason?.kind === 'max-tokens'
        ? 'completed'
        : endReason?.kind === 'aborted'
          ? 'aborted'
          : 'failed';
  const stopReason = cancelRequested ? 'cancelled' : (endReason?.kind ?? (outcome === 'lost' ? 'stream-lost' : 'no-turn-result'));
  const error =
    status === 'failed'
      ? {
          code: endReason?.error?.code ?? 'DSH_TURN_FAILED',
          message:
            endReason?.error?.message ??
            (outcome === 'lost' ? 'the session/follow stream was lost' : `DSH turn ended with ${stopReason}`),
        }
      : undefined;

  write({
    v: PROTOCOL_VERSION,
    type: 'result',
    request_id: requestId,
    session_id: sessionId,
    status,
    output: lastText,
    stop_reason: stopReason,
    resume_rejected: false,
    ...(error === undefined ? {} : { error }),
  });

  return status === 'completed' || status === 'cancelled' ? 0 : 1;
}

async function stdio() {
  const input = createInterface({ input: process.stdin, terminal: false, crlfDelay: Infinity });
  write({
    v: PROTOCOL_VERSION,
    type: 'ready',
    runtime: 'dsh',
    plugin_version: PLUGIN_VERSION,
    capabilities: {
      resume: true,
      cancel: true,
      models: true,
      thinking: true,
      usage: true,
      tools: true,
      mcp: [],
    },
  });

  let command;
  let cancelled = false;
  let resolveExecute = () => {};
  let resolveClosed = () => {};
  const closedEarly = new Promise((resolve) => {
    resolveClosed = resolve;
  });
  const firstExecute = new Promise((resolve) => {
    resolveExecute = resolve;
    input.on('line', (line) => {
      let frame;
      try {
        frame = JSON.parse(line);
      } catch {
        protocolError('INVALID_COMMAND', 'protocol command is not valid JSON');
        return;
      }
      if (frame?.v !== PROTOCOL_VERSION || typeof frame.type !== 'string') {
        protocolError('INVALID_COMMAND', 'unsupported protocol frame');
        return;
      }
      if (frame.type === 'execute') {
        if (command !== undefined) {
          protocolError('DUPLICATE_EXECUTE', 'this bridge accepts exactly one execute command');
          return;
        }
        command = frame;
        resolve();
        return;
      }
      if (frame.type === 'cancel' && command !== undefined && frame.request_id === command.request_id) {
        cancelled = true;
        cancelHandler();
        return;
      }
    });
  });

  input.on('close', () => {
    if (command === undefined) resolveClosed();
  });

  await Promise.race([firstExecute, closedEarly]);
  if (command === undefined) return 1;
  if (cancelled) return 0;
  const code = await runTask(command);
  input.close();
  return code;
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--version')) {
    process.stdout.write(`${process.env.DSH_BRIDGE_DSH_VERSION ?? '0.0.0'}\n`);
    return 0;
  }
  if (args.includes('--probe')) {
    write({
      v: PROTOCOL_VERSION,
      type: 'probe',
      runtime: 'dsh',
      plugin_version: PLUGIN_VERSION,
      protocol_version: PROTOCOL_VERSION,
    });
    return 0;
  }
  if (args.includes('--list-models')) {
    try {
      write({ v: PROTOCOL_VERSION, type: 'models', models: capCatalog(await listModels()) });
      return 0;
    } catch (error) {
      protocolError('STARTUP_FAILED', error instanceof Error ? error.message : String(error));
      return 1;
    }
  }
  if (args.includes('--stdio')) {
    try {
      return await stdio();
    } catch (error) {
      protocolError('STARTUP_FAILED', error instanceof Error ? error.message : String(error));
      return 1;
    }
  }
  process.stderr.write(`dsh-multica-bridge: unsupported mode: ${args.join(' ')}\n`);
  return 2;
}

process.exit(await main());
