# dsh-tui-remote

远程模式的 TUI 客户端（`dsh web` 常驻 core 的客户端）。设计与验收记录见
`docs/dsh-tui-remote-design.md` §12–§23。

## 内容

| 文件 | 用途 |
| --- | --- |
| `default.nix` | nix 构建：源码 + 补丁 → store 里的可运行树 |
| `remote-mode.patch` | 对上游 `v0.15.0` **源码**的完整改动（19 文件，+1867/−17） |

## 升级验收

改动 `tag`/`hash` 之后先跑契约自检，再开 TUI 手点：

```sh
dsh-tui-remote-verify                  # 描述符 / 方法名 / 事件字段 / compact 能力
```

12 项全过才算可用；失败说明上游动了客户端依赖的面（见设计文档 §30）。

## 怎么建

```sh
nix build .#dsh-tui-remote     # 已验证通过（2026-10-18）
```

四个 hash 都已填好（源码、pnpm 11 tarball、根 node_modules FOD、vendor node_modules FOD）。

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
