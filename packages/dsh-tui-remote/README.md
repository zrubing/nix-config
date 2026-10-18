# dsh-tui-remote

远程模式的 TUI 客户端（`dsh web` 常驻 core 的客户端）。设计与验收记录见
`docs/dsh-tui-remote-design.md` §12–§23、§36。

## 内容

| 文件 | 用途 |
| --- | --- |
| `default.nix` | nix 构建：源码 + 补丁 → store 里的可运行树 |
| `remote-mode.patch` | 对上游 `v0.16.1` **源码**的完整远程客户端改动 |
| `permission-presets.patch` | 叠加在上一份之上：Host 权限预设 → 远程会话 typed `modes`（`/permission`、Shift+Tab） |
| `startup-model.patch` | **暂存，未接入构建**：`--model` 启动路由，见下 |

## 权限模式（`/permission`）

远程会话没有内核，也没有 DSH extensions（`attachDshExtensions` 只挂 `native.dsh`）。
因此 `/permission` 不能走 DSH 的 `permissionPresets` 服务，而是走非 DSH 后端本来就有的
typed `modes` 能力：

1. `permissionPresets/catalog` 读 Host 的预设表（`read-only` / `workspace-write` /
   `danger-full-access`），挂载在 `connection.ts` 的可选 descriptor 上；老 Host 没有这个
   命名空间时，`modes` 不声明，`/permission` 保持不可用，连接本身不受影响。
2. `session/control` 的 `permissions.currentValue` 是当前身份；`modes.current()` 直接读它。
3. `modes.set(id)` 执行官方 `/permission <id>` 命令，并等投影确认；客户端不写
   `permission/preset` 事件。
4. 声明 `modes` 后，`channelCapabilities.commands` 自动把 `permission` 放进命令表，
   `/permission`（无参）打开「Permission mode」选择器，`/permission <preset>` 直切，
   `Shift+Tab` 按 `modes.list()` 顺序循环。
5. `auto` 被排除：它的 session 级风险确认只存在于 DSH 的 `/permission` 预设选择器里，
   当作普通 backend mode 展示会绕过风险门。

## `--model`（暂未接入）

以下为原设计，当前构建不包含该补丁：启动器仍会把 `--model` 的值搬进
`DSH_TUI_MODEL` 并从 argv 剔除，但远程入口不会读取它，等同于未设置。

`startup-model.patch` 保留为草稿，但**不在 `patches` 里**：

1. 它按旧版源码行号生成（`session.ts:1556`），套不上 v0.16.1；
2. 它依赖的 `agentDefaultModel.readConfig/editConfig` 在 Host 侧没有
   `typert.remote-client` 面，运行时也无法工作。

修好这两点前不参与构建，避免整个包被一个未验证的叠加补丁卡死。下面保留原设计说明，
供后续实现时对照。

`dsh-tui-remote --model deepseek-relay/deepseek-flash:max`（`--model=…` 亦可；
裸 `--model` 不带值时与 `DSH_TUI_MODEL` 同用，`dshTui` 同款约定）。

1. 启动器（`modules/home/dsh`）只把值搬进 `DSH_TUI_MODEL` 并从 argv 剔除 —— 不解析，
   否则 TUI 的启动提示词解析会把它当成要发的消息。
2. 远程入口解析成 `{provider, model, reasoningEffort?}`；没写 `:<effort>` 时用本机
   `/effort` 记住的档位，再没有就用宿主默认路由的档位。
3. 打开的会话（含 `/new` 新建的）若不是该路由，走一次 `session/selectModel`。
   该调用会把选择存成**部署默认模型**（`agent-default-model` 行整块替换），所以前后
   各读一次 `agentDefaultModel`，写完原样写回：`--model` 只影响这次启动，不搬动网页端
   的默认模型。恢复失败即失败，不吞。
4. 恢复已有会话时同样按起点校准（文档里"恢复的会话沿用其最后一次请求的路由"在远程
   模式下不成立 —— 那条规则是 TUI 自己的持久化，远程会话的路由由 Host 记录）。

夹具（构造 patch 时已核对，套在 remote-mode.patch 之上）：`entry.ts` 10 行上下文、
`session.ts:1556` 的 `close()` 收尾、`startup.ts` 的 `@@ -14/-21/-31/-94` ——
上游改这几处要跟着改。

## 升级验收

改动 `tag`/`hash` 之后先跑契约自检，再开 TUI 手点：

```sh
dsh-tui-remote-verify                  # 描述符 / 方法名 / 事件字段 / 权限 catalog / compact
```

全过才算可用；失败说明上游动了客户端依赖的面（见设计文档 §30）。升级时两份补丁都要
在干净的 `tag` 树上 `git apply --check`：`remote-mode.patch` 之后才是
`permission-presets.patch`。

## 怎么建

```sh
nix build .#dsh-tui-remote     # 已验证通过（2026-10-18）
```

四个 hash 都已填好（源码、pnpm 11 tarball、根 node_modules FOD、vendor node_modules FOD）。
2026-10-18 实际构建产物：`/nix/store/r0dmn71jwn825wyd90l2m2r4gckj2ss5-dsh-tui-remote-0.16.1`；
两个依赖 FOD 的 hash 已按 0.16.1 的真实依赖树回填。

启动由 `modules/home/dsh` 的 `dshTuiRemote` 包装器负责：`DSH_TUI_REMOTE_TREE` 现在指向
`${dsh-tui-remote}/libexec`，不再依赖 `.m1/` 开发树。

## 打包过程中撞到并解决的四件事

1. **pnpm 11 不在 nixpkgs**：从 npm 取 tarball 直接用，`passthru.nodejs-slim` 必须补
   （`pnpmConfigHook` 会 `inherit (pnpm) nodejs-slim`）。
2. **`fetchPnpmDeps` 会 `--force` 抓所有平台的可选二进制**（claude-agent-sdk / sharp /
   libreoffice-kit，数 GB）→ 网络超时。改成自定义 FOD：`pnpm install` +
   `supportedArchitectures: {os: [linux], cpu: [x64]}`，只取本平台。
3. **pnpm 11 的 supply-chain 校验只在 `pnpm-workspace.yaml` 里能关**，命令行
   `--config.trustPolicy=off` 无效（实测）。FOD 与构建都在清单顶部加
   `trustPolicy: off` / `minimumReleaseAge: 0`。
4. **`--no-optional` 会拆掉 esbuild/rolldown 的平台绑定**，`tsx`/`tsdown` 直接起不来；
   平台限制要用 `supportedArchitectures` 表达，不能用 `--no-optional`。
   另：安装产物里含指向 `vendor/` 的 workspace symlink，`installPhase` 必须一并拷
   `vendor/`，否则 `noBrokenSymlinks` 判失败。

另外：`src/dsh-adapter/remote/entry.ts` 已改为**不静态 import `@deepseek-ai/cordis`**
（改由 `createClientRoot()` 从被连接的安装解析），这是打包自洽的前提，也让 tarball 树
不需要自带框架包。

## 源码路线的构建配方（已在干净 clone 上验证）

```sh
git clone --depth 1 --branch v0.15.0 https://github.com/ccch1mneyyy/dsh-TUI tui
cd tui && git submodule update --init --recursive
git apply /path/to/remote-mode.patch
npm_config_cache=<writable> npx -y pnpm@11 install --frozen-lockfile --ignore-scripts --store-dir <store>
# vendor/dsh-std 的 7 个包必须先构建（scripts/build-vendor.mjs 会自己调 pnpm install，
# 在只读 HOME 的沙箱里会失败；直接跑它们的 tsc + tsdown 等价）
node --import tsx/esm scripts/gen-backend-index.mjs && npx tsc -p tsconfig.json && node scripts/gen-settings-json.mjs
```
