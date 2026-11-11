---
name: multica-dsh-bridge
description: 用于维护 multica 的 DSH runtime 桥——把 multica 的 stdio JSONL 协议翻译成对常驻 dsh-web host 的 remote RPC，使 multica 任务复用已在运行的 host 而不是每任务另起一个 dsh 进程。
---

# Multica ↔ DSH：web host 桥

当用户要求“让 multica 用我已经在跑的 dsh”、“multica 为什么又起了一个 dsh 进程”、
“multica 的 dsh 任务能不能在 web UI 里看到”时，使用此技能。

## 问题

multica 的 runtime 契约是「stdio 子进程 + JSONL」：daemon 执行
`dsh --profile multica --probe|--list-models|--stdio`，协议由 dsh 进程内的
`@multica-ai/dsh-runtime` 应答。这个形态有两个后果：

1. 每个任务都要完整组装一次 profile（实测 5.7–6.6s 首帧）。
2. 它与常驻的 `dsh-web`（`--profile nix-web`，3080）是**两个互不相干的进程**：
   任务不出现在 web UI / `dsh-tui-remote` 里，也不能被接管。

传输层对不上是根因：web host 对外是 HTTP/WS（`dsh-tui-remote` 连的就是它），
没有 stdio 入口；runtime 也没有 attach 到远程会话的传输层。

## 方案

一个独立进程顶替 `dsh` 这个可执行文件（`MULTICA_DSH_PATH`），两端翻译：

```
multica daemon
   │  spawn  <bridge> --profile multica --probe / --list-models / --stdio
   ▼
dsh-multica-bridge（Node，零第三方依赖）
   ├─ 上行：multica JSONL（execute / cancel）
   └─ 下行：connectRemote(http://127.0.0.1:3080) → session.create / prompt / cancel / session-follow
```

于是「一个 multica 任务 = 一个 host 会话」：任务出现在 web UI 与 `dsh-tui-remote`
里，模型表、MCP、权限全部来自 host 那套 profile，不再有第二份配置。

### 为什么复用 dsh-tui-remote 的模块

`dsh-tui-remote` 的 `remote/*.js` 本来就从「连接到的那个安装」动态加载客户端
（`dsh-client-connection` / `dsh-api-gateway` / `typert`），协议半边永远与 host 同源。
桥直接 import 它们（路径由 `DSH_TUI_REMOTE_TREE` 注入），不复刻一份 RPC 客户端。

## 两个硬约束

1. **可执行文件名必须是 `dsh`**。daemon 用 basename 识别 agent；名字不对时
   dsh 会被整条跳过（agents 列表里根本没有它），不报错。
   因此 nix 里额外产出一个只含 `bin/dsh` 软链的目录
   （`dsh-multica-bridge-as-dsh`），`MULTICA_DSH_PATH` 指向它的 `bin/dsh`。
2. **host 必须在跑**。桥不自己起 host；`dsh-web` 挂了任务即失败（daemon 会重试）。
   需要回退时把 `MULTICA_DSH_PATH` 去掉即可回到 `dsh --profile multica --stdio`。

## 协议映射

| multica 帧 | 来源 |
|---|---|
| `probe` | 常量应答，不连 host |
| `models` | host 的 `session/modelCatalog`（与 TUI 里看到的一致） |
| `ready` | 常量 + capabilities |
| `session` | `session.create` 返回的 host sessionId；resume 时回显入参 |
| `text` / `thinking` / `usage` | `session/follow` 的 `assistant/message` 事件 |
| `tool_call` / `tool_result` | 同上的 `tool/call`、`tool/result` |
| `result` | `turn/end` 的 reason（completed / aborted / error / max-tokens） |
| cancel 命令 | `session.cancel` |

## 代码位置

1. `pkgs/dsh-multica-bridge/bridge.mjs`：协议翻译，唯一实现处。
2. `pkgs/dsh-multica-bridge/default.nix`：wrapper，注入 `DSH_HOST_PACKAGE`、
   `DSH_TUI_REMOTE_TREE`、`DSH_BRIDGE_DSH_VERSION`。
3. `modules/home/dsh/default.nix`：产出桥、`-as-dsh` 目录，并以 readOnly 选项
   `modules.dsh.multicaBridge` 暴露。
4. `modules/home/multica/default.nix`：daemon 单元的 `MULTICA_DSH_PATH`。

## 验证

```bash
b=$(systemctl --user show multica-daemon -p Environment | tr ' ' '\n' | sed -n 's/^MULTICA_DSH_PATH=//p')
"$b" --version                     # 应输出 host dsh 的版本
"$b" --profile multica --probe     # {"v":1,"type":"probe",...}
"$b" --list-models | head -c 200   # {"v":1,"type":"models",...}
printf '%s\n' '{"v":1,"type":"execute","request_id":"t1","cwd":"/tmp","prompt":"只回复两个字：收到"}' \
  | "$b" --profile multica --stdio  # ready → session → text → usage → result
```

daemon 侧看注册用的路径：

```bash
journalctl --user -u multica-daemon -n 200 --no-pager | grep -E "version detected|registered runtime"
```

`path=` 应指向 `…-dsh-multica-bridge-as-dsh/bin/dsh`。

## 已知边界

1. `mcp_servers` 参数被忽略：MCP 由 host profile 提供，任务不额外注入。
2. `model` / `reasoning_effort` 被忽略：沿用 host 会话的默认选择。
3. resume 依赖 host 侧 sessionId 仍然存在；跨 host 重启后可能失效，此时
   `result.resume_rejected` 为 false 但状态是 failed。
