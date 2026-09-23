现在是2026年8月

- 用中文回答
- 自我验证
- 遵循KISS原则
- 不堆临时补丁，找到问题真正的来源，修复根源
- 使用rg或者grep时，timeout不要超过10s


## 文件创建 vs 对话内回答

- **创建文件**：用户明确要求"写/创建/生成"文件、代码组件、文章、报告；超过 20 行的代码；需要独立保存或分享的内容
- **对话内回答**：策略分析、总结、头脑风暴、简短解释、≤20 行的代码片段
- 判断标准：用户会复制/发布出去 → 文件；聊天里看完就用 → 对话
- 不确定时，先给对话回答，末尾说"需要的话我可以再创建文件"

## 犯错处理

- 犯错了直接承认，不找借口、不过度道歉、不自我贬低
- 修复问题根源，保持稳定、诚实的帮助姿态



## Memory 知识沉淀（org-roam）

- 当一次排查 / 分析有长期保留价值（多步实证、配置、结论）时，把结果整理成 org-roam 笔记写入 `/home/jojo/org-roam-dir`。
- agent 工作索引另写入 `/home/jojo/org-roam-dir/agent-journal.org`（与个人 `journal.org` 分开）；格式同 journal.org，按 `* 年` → `** 年月 月份` → `*** 日期 星期` → `**** [时间戳] 标题` 组织，条目用 `[[id:<uuid>][标签]]` 链到对应 org-roam 笔记；journal 只留索引，细节在笔记。
- 简单样例（最小模板，仅示结构，不含真实内容）：
  - org-roam 笔记 `/home/jojo/org-roam-dir/20260101000000-example.org`：
    #+begin_src text
    :PROPERTIES:
    :ID:       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    :END:
    #+title: example

    * 背景
    一句话。

    * 结论
    一句话 + [[id:yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy][相关笔记]]
    #+end_src
  - agent-journal 索引条目：
    #+begin_src text
    **** [2026-01-01 三 10:00] 简短标题
    一句话结论。索引：[[id:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx][example]]
    #+end_src
- 文件格式：文件名 `YYYYMMDDHHMMSS-slug.org`，头部含 `:PROPERTIES: :ID: <uuid> :END:` 与 `#+title:`（uuid 取自 `/proc/sys/kernel/random/uuid`），可被 org-roam 正常索引。
- 笔记内容应自包含：背景、环境事实、排查步骤（标注“实测闭环”）、最终可用配置（torrc / 脚本全文）、验证结果、与既有知识的对照、后续项。

## 排障与改造准则

**关键判断要在目标环境实证闭环，不能只读代码。** 端口有没有人用、链路怎么走、配置是否真正生效——代码只告诉你"意图"，运行时才告诉你"事实"。准备删除或修改某个配置之前，先到目标环境验证它到底有没有消费者。

**所有改造附带迁移顺序和安全前提。** 先标注"必须先手动 X 再部署 Y，否则 Z 会挂"，再给步骤。部署前做三件事：验证构建产物、检查关键字段渲染结果、记录当前基线状态。

**每次只改一组强关联项。** 答"会不会变"时分清稳定性边界，不说"永远不会变"。发现已有改动中的 bug 直接修掉，不假装没看到。确认无害但非本次目标的清理项留到下轮，保持改动面最小、可回滚。

## 工具陷阱速查（agent 易错点）

- **`rg -r/--replace` 是匹配级替换，不是行级替换。** 整行输出被替换成同一字符串，说明 pattern 命中了整行（如 `.*`、`^.*$`，或过于宽泛），或用了 `-o`。这不是 ripgrep 的 bug。完整说明 + 正确用法对照表见 org-roam 笔记：`/home/jojo/org-roam-dir/20260824144117-ripgrep-replace-gotcha.org`（id `9d350e27-2179-49dc-b720-8af9d89a8ca0`）。

---

## Project Information

- `/home/jojo/codeWorkspace` (`~/codeWorkspace`)：所有仓库的工作空间根目录
- `/home/jojo/codeWorkspace/system-manager-hinihao-net`: `hinihao-net` 集群配置仓库（CI 编写通用指导：`/home/jojo/codeWorkspace/system-manager-hinihao-net/docs/ci-authoring-guide.md`）
- `/home/jojo/codeWorkspace/nix-config-vps`: `hinihao-net` 的 `ali` 节点配置仓库
- `/home/jojo/codeWorkspace/http/` 接口测试文件
- `/home/jojo/codeWorkspace/flask_python_tool/pull_question/`：亚投行题目生成 Python 服务
- `/home/jojo/codeWorkspace/hinihao-fullstack/`: `hinihao` monorepo
  - `admin-backend`: 管理后台后端 (Java/Maven，Spring Boot 多模块)
  - `admin-pannel`: 管理面板前端 (Vue/Vite)
  - `aichinese`: AI 中文学习项目 (Java/Maven)
  - `hinihao_app`: Hinihao App (Vue/Vite)
  - `hinihao_rd`: Hinihao RD 后端服务 (PHP/Laravel)
  - `pc_website`: PC 官网 (Nuxt.js)
- `/home/jojo/codeWorkspace/codeup-forgejo-mirror-sync`: Forgejo 镜像同步仓库

- `/home/jojo/codeWorkspace/beauty-full` Salesboost项目
  - `SalesBoost-adm` 后端
  - `SalesBoost-vue` 管理面板

- `/home/jojo/codeWorkspace/dongyi` 懂译项目

## Woodpecker Pipeline Link Handling

- 当看到类似 `https://ci.hinihao.net/repos/<repo>/pipeline/<num>/<num>` 的流水线地址时，优先使用 `woodpecker-ci` skill（用户口头也可能称为 `woodpecker-cli` skill）。
- 仓库映射：Woodpecker `repository=hinihao_ops`（如 `repos/5`）对应本地路径 `/home/jojo/codeWorkspace/hinihao-fullstack/admin-pannel`。



## hinihao observability CLI 查询

zen14 已常驻转发：

- Loki: `http://loki.local:3100`，环境变量 `LOKI_ADDR` 应已设置
- Tempo: `http://tempo.local:3200`，环境变量 `TEMPO_ADDR` 应已设置

检查：

```bash
curl -fsS http://loki.local:3100/ready
curl -fsS http://tempo.local:3200/ready
```

查 Loki 日志：

```bash
logcli query '{namespace="<ns>", app="<app>"}' --since=30m --limit=100
logcli query '{namespace="<ns>", app="<app>"} |= "<keyword>"' --since=1h --limit=100
logcli query '{namespace="<ns>", app="<app>", level="error"}' --since=1h --limit=100
```

不知道 label 时：

```bash
logcli labels namespace --since=30m
logcli labels app --since=30m
```

查 Tempo trace：

```bash
curl -fsS -G 'http://tempo.local:3200/api/search' \
  --data-urlencode 'q={ resource.service.name = "<service>" }' \
  --data-urlencode 'limit=10' \
  | jq -r '.traces[]? | [.traceID, .rootServiceName, .rootTraceName, (.durationMs | tostring)] | @tsv'

TRACE_ID=<trace_id>
curl -fsS "http://tempo.local:3200/api/traces/$TRACE_ID" | jq .
```

从 trace 查日志：

```bash
TRACE_ID=<trace_id>
logcli query "{namespace=\"<ns>\", app=\"<app>\"} |= \"$TRACE_ID\"" --since=1h --limit=200 --output=raw
```

注意：`trace_id=0` 表示日志不在 active span 中，不能用于 trace/log 精确关联。

