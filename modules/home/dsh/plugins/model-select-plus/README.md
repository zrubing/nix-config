# @local/dsh-model-select-plus

DSH Web 的 composer 模型座位（`conversation.input.model`）替换插件：菜单顶部内置
搜索框，模型行显示为 `Provider / model`。

- 复用官方 `@deepseek-ai/dsh-client-ui-model-selection` 挂载的
  `ModelDirectoryResolver`（`ctx.modelDirectories`），数据面（加载 / 选择 /
  失败重试 / 会话持久化）完全走官方；本插件不重复注册 resolver，也不触碰
  `/model` 命令。
- 官方座位组件保持挂载，被本插件在同名单座位上的后注册者遮蔽（single slot
  的 shadowing 语义：后注册者优先级数值更低、胜出）。
- 保留官方行为：Model / Effort 两级菜单、选中高亮 + 对勾、↑↓/Enter/Esc 键盘
  导航、目录失败行 + 重试、点击外部关闭、子代理会话不渲染。
- 新增：搜索框自动聚焦，按 provider 名/id 与模型名/id 忽略大小写子串过滤；
  无匹配显示空态；Esc 逐级返回（有搜索词时先清空搜索词）。

## 安装（nix 管理）

源码随 nix-config 仓库分发：`modules/home/dsh/plugins/model-select-plus/`。
`modules/home/dsh/default.nix` 中的 `configureDshModelSelectPlus` activation
把它以 `file:` 依赖装入 web profile（内容变更 → store hash 变化 → 自动重装 +
重启服务），loader 行由 nix 托管的 `~/.dsh/cordis.patch.yml`（`providerPatch`）
以 `- insert` 提供。`home-manager switch` 后生效。

## 文件

- `lib/index.js` — host 半区，空 `apply`（loader 行占位）。
- `lib/client.js` — 浏览器半区，`window.__ModuleLoader__.load` 单文件产物；
  仅依赖 vendor seed 模块（`react` / `react/jsx-runtime` /
  `@deepseek-ai/dsh-client-ui-primitives`），无第三方 npm 依赖。
