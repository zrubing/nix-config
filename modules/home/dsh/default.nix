{
  config,
  lib,
  pkgs,
  inputs,
  system,
  namespace,
  ...
}:
let
  cfg = config.${namespace}.modules.dsh;
  # dsh 二进制来源：默认用 llm-agents 打包的 npm 版（@deepseek-ai/dsh 0.1.1-rc.2）；
  # useDshSource=true 改用从 deepseek-harness 源码构建的本仓库包（packages/dsh-source，
  # 即 Moraxyc 式 kernel 方案产出的 dsh-kernel，版本/源码单一来源 =
  # flake input deepseek-harness-src（当前锁 tag dsh-v0.1.7-alpha.2，升级见
  # pkgs/dsh-moraxyc/dsh-workspace/package.nix 注释）。
  # llm-agents 更新后把 useDshSource 改回 false 即切回。
  dshPackage =
    if cfg.useDshSource
    then import ../../../packages/dsh-source { inherit lib pkgs inputs; }
    else inputs.llm-agents.packages.${system}.dsh;
  # 本地 plugin（tool-processes / compact-blackhole）导入 @deepseek-ai/* 的 node_modules 根。
  # llm-agents npm 版与源码 kernel 版布局不同，按后端切换。
  dshNodeModules =
    if cfg.useDshSource
    then "${dshPackage}/lib/deepseek-harness/node_modules"
    else "${dshPackage}/lib/node_modules/@deepseek-ai/dsh/node_modules";
  # activation 跑在系统级 home-manager-jojo.service 里，unit 的 PATH 只有
  # coreutils/grep 等基础包（hm-setup-env 不导入用户 session 的 PATH），
  # dsh plugin 内部 spawn 的 pnpm 找不到 → 安装静默失败（WARN 进系统 journal）。
  # 所有会调 dsh plugin 的 activation 块必须先补上用户 profile bin。
  username = config.snowfallorg.user.name;
  userBin = "/etc/profiles/per-user/${username}/bin";

  # 统一 MCP server 定义（pi / dsh 共用源，见该文件头部注释）：新增或修改
  # server 只改那一个文件；此处把同一份源渲染成 cordis insert 条目，密钥走
  # !!js process.env.VAR（值由 dsh.env 注入），与 pi 侧的 ${VAR} 引用同源。
  mcpServers = import ../mcp-servers/servers.nix { inherit lib pkgs namespace; };

  # dsh web 服务跑在无 DISPLAY 的 systemd user 环境里（has_display=false），xdg-open 会
  # 跳过 mime 关联查找、直接走 BROWSER 兜底；BROWSER 空 + 无终端浏览器（www-browser 等全
  # 未装）→ "no method available for opening '...'"，GUI 点文件路径即报这个错。给服务注入
  # BROWSER=dsh-file-open：文件路径交给 emacsclient（用户默认 editor，--create-frame，
  # 连 daemon 开新帧显示）；URL 回落给系统 xdg-open（避免把 http(s) 链接塞给 emacs）。
  # URL 回落前必须 unset BROWSER：xdg-open 的 open_generic 兜底对 URL 会同步调用
  # $BROWSER（open_envvar，等退出码），若 BROWSER 仍指向本脚本 → 本脚本又 exec 回
  # xdg-open → 无限嵌套 fork（2026-09-06 实测：9 分钟堆 2.7 万进程、吃 20G 内存；
  # xdg-open 自身只对 BROWSER 含 "xdg-open" 字面量做防自递归 sanitize，防不了这种
  # 包装器回环）。unset 后 xdg-open 走正常 scheme-handler/已知浏览器探测，无兜底则
  # 优雅报 "no method available"。文件路径分支不受影响（open_envvar 传路径给本脚本 →
  # 落到下方 emacsclient，不再经过 xdg-open）。
  dshFileOpener = pkgs.writeShellScriptBin "dsh-file-open" ''
    real_xdg_open=/run/current-system/sw/bin/xdg-open
    for arg in "$@"; do
      case "$arg" in
        http://*|https://*|ftp://*|file://*|mailto:*)
          unset BROWSER
          exec "$real_xdg_open" "$@"
          ;;
      esac
    done
    # dsh-web 服务无 DISPLAY 且无 tty：emacsclient --create-frame 会先取终端名而报
    # "could not get terminal name"；而 emacs daemon 常以缺 DISPLAY 的 systemd 服务启动、
    # 初始为 terminal 模式（window-system=nil），直接开帧会报 "unknown terminal type"。故用
    # --eval 把文件交给 daemon：若 daemon 尚无图形帧（本 emacs 为 X11 构建，靠 XWayland :0
    # 提供窗口），优先复用当前图形帧（用户在看的那个），没有图形帧才在 XWayland :0 新建；打开文件后
    # select-frame-set-input-focus + raise-frame，让显示该文件的窗口聚焦到前台。
    # 客户端只连 server socket，无需 tty/display。路径转义成 Lisp 字符串字面量（\ 与 "）。
    path="$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    emacsclient --eval "(progn (let* ((cur (selected-frame)) (gf (or (and (display-graphic-p cur) cur) (let ((found nil)) (dolist (f (frame-list) found) (when (and (frame-live-p f) (display-graphic-p f)) (setq found f)))))) (frame (or gf (make-frame (list (cons 'display \":0\")))))) (with-selected-frame frame (find-file \"$path\")) (select-frame-set-input-focus frame) (raise-frame frame)) t)"
  '';

  # ── DSH 专用浏览器实例 ────────────────────────────────────────────────
  # 目的：让 Web UI 的窗口能被 niri 单独识别（固定到 code 工作区），同时主 Brave
  # 窗口不受任何影响。niri 只按 app-id/title 匹配窗口，而 Brave 所有窗口 app-id 都是
  # brave-browser —— 靠窗口标题区分会在标题变化时失效，所以从根上给这个实例独立身份：
  # 单独 user-data-dir + 显式 --class。
  #
  # 不用 modules/home/linux-desktop 的 brave-wrapper：那个 wrapper 无条件追加
  # ~/.config/brave-flags.conf（内含 --remote-debugging-port=9222），第二个实例带同
  # 端口起不来；而 9222 又是主实例专属、brave-tab-switcher-v2 依赖的调试端口。
  #
  # --class 是 Chromium 的窗口类开关，Wayland 下即 app_id。首次启动后用
  # `niri msg pick-window` 点该窗口确认 app_id 是否为 brave-dsh；若 Brave 实际落在
  # XWayland（app-id 变成 brave-browser），只需把 wayle 模块里对应 niri 规则的
  # match app-id 换成 match title，启动器本身不用动。
  dshBrowser = pkgs.writeShellScriptBin "dsh-browser" ''
    exec ${lib.getExe pkgs.brave} \
      --user-data-dir="$HOME/.local/share/dsh-brave" \
      --class=brave-dsh \
      --no-first-run \
      --no-default-browser-check \
      "$@"
  '';

  # 本地 dsh 插件：中和 MCP 工具描述带进 prompt section 的未注册 {{...}} 组
  # （如 apipost get_target_detail 的字面示例 {{paramName}}），否则
  # dsh-system-prompt 严格渲染器抛 "malformed prompt variable reference"
  # 导致整轮对话失败（上游已知问题 #711，rc.2 无转义语法未修）。
  # 已注册变量（model/cwd 等）保留插值；单测见仓库 .braces-sanitize-test.mjs。
  bracesSanitizePlugin = pkgs.runCommand "dsh-braces-sanitize" { } ''
    mkdir -p $out
    cp ${./plugins/braces-sanitize/package.json} $out/package.json
    cp ${./plugins/braces-sanitize/index.js} $out/index.js
  '';

  # OpenBao LDAP agent 密码注入（shell-env 注册表）：dsh 的子进程 env 构建会
  # 擦除名字匹配 KEY|PASSWORD|SECRET|TOKEN 的宿主变量（scrubbedParentEnv，
  # 刻意安全设计），但 shell-env 注册表是官方受信通道（DSH_* 命名空间，每次
  # shell 调用重建、经 executor 在 scrub 之后注入）。本插件照 dsh-web-app 的
  # 官方范例注册 contributor：resolver 从宿主进程 env 读
  # OPENBAO_LDAP_AGENT_PASSWORD（dsh-web-start 已 source dsh.env），注入为
  # DSH_OPENBAO_LDAP_AGENT_PASSWORD。agent 配合 OPENBAO_LDAP_AGENT_USERNAME
  # （非敏感名，不受 scrub）+ BAO_ADDR 即可 bao login 零交互取动态 MySQL 凭证。
  # 装载 = activation 以 file: 依赖装入 web profile + 本文件 providerPatch 的
  # insert 行；同 braces-sanitize 双件套。
  openbaoShellEnvPlugin = pkgs.runCommand "dsh-openbao-shell-env" { } ''
    mkdir -p $out
    cp ${./plugins/openbao-shell-env/package.json} $out/package.json
    cp ${./plugins/openbao-shell-env/index.js} $out/index.js
  '';

  # Woodpecker CLI 服务器/令牌注入（shell-env 注册表）：woodpecker-cli 读
  # WOODPECKER_SERVER/WOODPECKER_TOKEN（3.16 源码 cli/common/flags.go 实测），
  # 但 WOODPECKER_TOKEN 命中 dsh subprocess 的敏感名 scrub
  # （/KEY|PASSWORD|SECRET|TOKEN/i）——即便 dsh.env 渲染了它（dsh-web-start
  # source 后进程内有），agent 的 shell 也拿不到。同 openbao 插件：注册
  # contributor（resolve 从宿主进程 env 读回 WOODPECKER_*，注入为
  # DSH_WOODPECKER_*）。AGENT 侧无需文档或 skill 说明：dsh.env 另有 BASH_ENV
  # 行指向 dsh-bash-env.sh，模型每次非交互 bash 启动自动把 DSH_WOODPECKER_*
  # 转回 WOODPECKER_*，woodpecker-cli 开箱即用（交互 persistent shell 由
  # ~/.bashrc 覆盖）。装载 = activation 以 file: 依赖装入 web profile +
  # 本文件 providerPatch 的 insert 行；同 openbao 双件套。
  woodpeckerShellEnvPlugin = pkgs.runCommand "dsh-woodpecker-shell-env" { } ''
    mkdir -p $out
    cp ${./plugins/woodpecker-shell-env/package.json} $out/package.json
    cp ${./plugins/woodpecker-shell-env/index.js} $out/index.js
  '';

  # HuggingFace token 注入（shell-env 注册表）：hf CLI（huggingface_hub）与
  # transformers/datasets 读 HF_TOKEN，但该名字命中 dsh subprocess 的敏感名
  # scrub（/KEY|PASSWORD|SECRET|TOKEN/i）——即便 dsh.env 渲染了它
  # （dsh-web-start source 后进程内有），agent 的 shell 也拿不到。同 woodpecker
  # 插件：注册 contributor（resolve 从宿主进程 env 读回 HF_TOKEN，注入为
  # DSH_HF_TOKEN）。dsh-bash-env.sh 自动把 DSH_HF_TOKEN 转回 HF_TOKEN，模型
  # 直接 `hf download` 开箱即用。装载 = activation 以 file: 依赖装入 web
  # profile + 本文件 providerPatch 的 insert 行；同 openbao/woodpecker 双件套。
  hfShellEnvPlugin = pkgs.runCommand "dsh-hf-shell-env" { } ''
    mkdir -p $out
    cp ${./plugins/hf-shell-env/package.json} $out/package.json
    cp ${./plugins/hf-shell-env/index.js} $out/index.js
  '';

  # composer 模型座位替换（可搜索 + Provider 前缀）。client-ui 插件：host 半区
  # 空 apply 占位，浏览器半区 lib/client.js 是手写的 __ModuleLoader__.load 单文件
  # 产物（vendor seed 模块 react / jsx-runtime / ui-primitives 之外零依赖）。
  # 数据面复用官方 ui-model-selection 的 ModelDirectoryResolver（ctx.modelDirectories），
  # 不重复挂载 resolver、不动 /model 命令；官方座位组件保持挂载，被本插件在同
  # `conversation.input.model` 单座位上的后注册者遮蔽（single slot shadowing：
  # 后注册优先级数值更低、胜出）。装载 = activation 以 file: 依赖装入 web
  # profile（configureDshModelSelectPlus）+ 本文件 providerPatch 的 insert 行；
  # 与 braces-sanitize 同款双件套。headless 未装包时该 insert 行仅告警跳过。
  modelSelectPlusPlugin = pkgs.runCommand "dsh-model-select-plus" { } ''
    mkdir -p $out/lib
    cp ${./plugins/model-select-plus/package.json} $out/package.json
    cp ${./plugins/model-select-plus/lib/index.js} $out/lib/index.js
    cp ${./plugins/model-select-plus/lib/client.js} $out/lib/client.js
  '';

  # 自动发现 opencode-go 实时模型（见 plugins/opencode-autosync/lib/index.js 注释）。
  # host-only 插件，零 @deepseek-ai/* 导入（不走 node_modules shim）：服务全部经
  # ctx.get 惰性解析，网络发现复用 ctx.llm.discoverModels（provider 故意省略以绕过
  # dsh-llm-pi-ai 对 catalog provider 的短路，见插件源码 Why）。构建产物只含
  # package.json + lib/index.js，activation 以 file: 装入 web profile；loader 行
  # 在 providerPatch 的 opencode-autosync insert 条目。同 braces-sanitize /
  # model-select-plus 双件套。headless 未装包时该行仅告警跳过。
  opencodeAutosyncPlugin = pkgs.runCommand "dsh-opencode-autosync" { } ''
    mkdir -p $out/lib
    cp ${./plugins/opencode-autosync/package.json} $out/package.json
    cp ${./plugins/opencode-autosync/lib/index.js} $out/lib/index.js
  '';

  # 自动发现 runinfra 实时模型（见 plugins/runinfra-autosync/lib/index.js 注释）。
  # host-only 插件，零 @deepseek-ai/* 导入：服务全部经 ctx.get 惰性解析，网络
  # 发现复用 ctx.llm.discoverModels（provider 故意省略以走网络分支）。与
  # opencode-autosync 不同，runinfra 是单一 openai-completions 网关，其
  # /v1/models 是权威，故这里采用 reconcile（增删同步）而非 add-only——保留
  # 仍在 live 的既有条目（含 compat/reasoningEfforts/用户修正容量）、追加
  # 新出现 id（带 RunInfra 安全默认：developer role 400 故
  # supportsDeveloperRole:false）、并丢弃网关已下架 id。构建产物只含
  # package.json + lib/index.js，activation 以 file: 装入 web profile；loader
  # 行在 providerPatch 的 runinfra-autosync insert 条目。headless 未装包时该行
  # 仅告警跳过。
  runinfraAutosyncPlugin = pkgs.runCommand "dsh-runinfra-autosync" { } ''
    mkdir -p $out/lib
    cp ${./plugins/runinfra-autosync/package.json} $out/package.json
    cp ${./plugins/runinfra-autosync/lib/index.js} $out/lib/index.js
  '';

  # 自动发现 deepseek-relay 实时模型（见 plugins/deepseek-relay-autosync/lib/index.js
  # 注释）。dsh-runinfra-autosync 的克隆，仅默认端点/路由/凭据 env 不同：
  # relay /v1/models 是权威，reconcile（增删同步）deepseek-relay 路由——中转侧
  # 改名（如 v4.1-flash-expires-on-0910 → v4.1-flash）、上新、下架都自动跟随，
  # 不再需要手动改 providerPatch 种子表。headless 未装包时该行仅告警跳过。
  deepseekRelayAutosyncPlugin = pkgs.runCommand "dsh-deepseek-relay-autosync" { } ''
    mkdir -p $out/lib
    cp ${./plugins/deepseek-relay-autosync/package.json} $out/package.json
    cp ${./plugins/deepseek-relay-autosync/lib/index.js} $out/lib/index.js
  '';

  # pi-processes（aliou）的 agent 侧移植。pi extension（@earendil-works/* 契约 +
  # TUI 面板）无法被 dsh 加载——dsh 唯一的 pi 关联包 dsh-llm-pi-ai 只是 LLM API
  # 适配层，不是 extension 宿主。这里移植对 agent 真正有用的半区：start_process
  # 工具后台起进程不阻塞对话，进程句柄注册进 host 的 ctx.jobs（完成通知 /
  # job_output 增量读 / job_kill 终止 / web UI jobs 面板全部复用），收集工具由
  # preset 里的 tool-jobs 行提供。preset 声明行用相对说明符
  # ./nix-presets/tool-processes.js 加载（baseUrl = web profile 目录，见下方
  # presetAssets），该目录的 node_modules 目录级 shim 解析裸 @deepseek-ai/* 导入
  # （本 derivation 自带的 shim 只对单文件部署的老布局有用，留着不影响）。
  toolProcessesPlugin = pkgs.runCommand "dsh-tool-processes" { } ''
    mkdir -p $out
    cp ${./agent-presets/my-minimal/tool-processes.js} $out/tool-processes.js
    ln -s ${dshNodeModules} $out/node_modules
  '';

  # ast-grep 结构化搜索/改写工具（`ast_grep`）。同 tool-processes：源码 + node_modules
  # shim 构建进同一 store 路径，再由 presetAssets 以 ./nix-presets/tool-ast-grep.js
  # 供 my-minimal / my-ptc / my-router-standard 三个 preset 共用。命令必须是
  # `ast-grep` 全名——本机 `sg` 被 shadow 的组切换命令占用，且 dsh-web 服务的
  # PATH 里 system sw/bin 在 per-user bin 之前。
  toolAstGrepPlugin = pkgs.runCommand "dsh-tool-ast-grep" { } ''
    mkdir -p $out
    cp ${./agent-presets/my-minimal/tool-ast-grep.js} $out/tool-ast-grep.js
    ln -s ${dshNodeModules} $out/node_modules
  '';

  # pi-blackhole (k0valik @0.4.3) 适配器 —— 独立 dsh 插件包（modules/home/dsh/plugins/dsh-blackhole，
  # 不是 Snowfall 的 packages/：它需要 dsh 模块独有的 dshNodeModules，不能进 flake packages 输出）。
  # 采用「导入上游核心」的适配器模式：nix 让包的 scripts/build.sh 用 esbuild 把 pi-blackhole 的纯 TS
  # 核心（src/core/summarize.ts 的 compile 管线 + recall 检索，仅依赖 node 内建 + 一个 pi-tui
  # wrapTextWithAnsi 占位）打成 ESM bundle，dsh 侧只保留薄适配器：to-pi.js（dsh Message -> pi
  # Message）、compaction 引擎（覆写 summarize()）、recall 工具、OM worker、/blackhole* 命令。
  # 上游更新 = flake.lock 换 rev + rebuild，不再手工 re-port。阈值、/compact、<compacted-summary>、
  # tool-result pruner 沿用 dsh。
  blackholePlugin = import ./plugins/dsh-blackhole/build.nix { inherit lib pkgs inputs dshNodeModules; };

  # ── 本地 Agent Preset（dsh 0.1.7 起为声明式，目录机制已删除）──────────────
  # 0.1.7 起上游删除了 $DSH_HOME/.agent-presets 目录机制（上游 note
  # .agents/notes/implemented/architecture/2026-09-18-declarative-agent-presets.md
  # 与随包发布的 editing-cordis-compositions skill）：preset 不再是目录，而是
  # bundle/profile patch 里的一条 @deepseek-ai/dsh-agent-preset 声明行
  # （Loader 行 id 约定 preset-<id>，config.plugins 是普通 cordis 行数组）。
  #
  # 本模块把 4 个本地 preset 的声明写进 web profile 的 user layer
  # （$DSH_HOME/profiles/web/cordis.patch.yml，见下方 webProfilePatch）。该层是
  # dsh 定义的 "the user's own patch layer, applied after every bundle layer"，
  # 正好叠在 shipped minimal/ptc 之上；声明行所在配置树的 baseUrl = profile 目录
  # （apps/cli 的 PROFILE_ROOT_FILENAME 就在该目录），所以行里的相对说明符
  # ./nix-presets/... 解析到 presetAssets 落地在 ~/.dsh/profiles/web/nix-presets
  # 的资源。
  #
  # 与 0.1.6 目录版的一一对应：
  #   my-minimal = shipped `minimal` 的 plugins + agent-presets/my-minimal/extras.cordis.yml
  #   my-ptc     = shipped `ptc` 的 plugins（compaction 组的 compaction-basic 行换成
  #                ./nix-presets/dsh-blackhole/lib/compaction.js）+ my-ptc/extras.cordis.yml
  #   router-standard / my-router-standard = 各自 agent.cordis.yml 的整份行数组
  # shipped plugins 仍在构建期从 flake input 读，上游更新自动跟随；声明的
  # id/name/description/order 沿用各自 preset.yml。
  presetAssets = pkgs.runCommand "dsh-local-presets" { } ''
    mkdir -p $out/router-standard $out/my-router-standard
    install -m644 ${toolProcessesPlugin}/tool-processes.js $out/tool-processes.js
    install -m644 ${toolAstGrepPlugin}/tool-ast-grep.js $out/tool-ast-grep.js
    cp -r ${blackholePlugin} $out/dsh-blackhole
    install -m644 ${./agent-presets/router-standard/router-bootstrap-v34.mjs} $out/router-standard/router-bootstrap-v34.mjs
    install -m644 ${./agent-presets/router-standard/router-core-v34.mjs} $out/router-standard/router-core-v34.mjs
    install -m644 ${./agent-presets/router-standard/gitbash-executor.mjs} $out/router-standard/gitbash-executor.mjs
    install -m644 ${./agent-presets/my-router-standard/router-bootstrap-v34.mjs} $out/my-router-standard/router-bootstrap-v34.mjs
    install -m644 ${./agent-presets/my-router-standard/router-core-v34.mjs} $out/my-router-standard/router-core-v34.mjs
    install -m644 ${./agent-presets/my-router-standard/gitbash-executor.mjs} $out/my-router-standard/gitbash-executor.mjs
    # my-router-standard 的组合既有自己的 router-*.mjs，也引用共用的 dsh-blackhole /
    # tool-ast-grep.js；同目录符号链接让「相对说明符统一加
    # ./nix-presets/my-router-standard/ 前缀」这条重写规则对两者都成立。
    ln -s ../dsh-blackhole $out/my-router-standard/dsh-blackhole
    ln -s ../tool-ast-grep.js $out/my-router-standard/tool-ast-grep.js
    # 散装 @deepseek-ai/* 裸导入的目录级 shim（preset 资源目录向上没有 node_modules；
    # toolProcessesPlugin/toolAstGrepPlugin 自带的 shim 只在各自 store 包内生效）。
    ln -s ${dshNodeModules} $out/node_modules
    chmod -R u+w $out
  '';

  # 声明行在构建期生成（eval 期不解析 YAML）：取 shipped patch 的 plugins、追加本地
  # extras、替换 compaction 后端、把相对说明符重写到 presetAssets 布局。上游形状变化
  # （shipped ptc 的 compaction-basic 行不再是恰好一条）会让本 derivation 直接失败，
  # 不会静默漂移。
  presetDeclarations = pkgs.runCommand "dsh-local-preset-declarations.yml" {
    nativeBuildInputs = [ pkgs.yq-go ];
    MIN_UP = "${inputs.deepseek-harness-src}/packages/bundle/web-app/presets/minimal.patch.yml";
    MIN_EX = ./agent-presets/my-minimal/extras.cordis.yml;
    MIN_META = ./agent-presets/my-minimal/preset.yml;
    PTC_UP = "${inputs.deepseek-harness-src}/packages/bundle/web-app/presets/ptc.patch.yml";
    PTC_EX = ./agent-presets/my-ptc/extras.cordis.yml;
    PTC_META = ./agent-presets/my-ptc/preset.yml;
    ROUTER_COMP = ./agent-presets/router-standard/agent.cordis.yml;
    ROUTER_META = ./agent-presets/router-standard/preset.yml;
    MYROUTER_COMP = ./agent-presets/my-router-standard/agent.cordis.yml;
    MYROUTER_META = ./agent-presets/my-router-standard/preset.yml;
  } ''
    for patch in "$MIN_UP" "$PTC_UP"; do
      yq -e '.[0].insert[0].name == "@deepseek-ai/dsh-agent-preset"' "$patch" >/dev/null || {
        printf 'dsh local presets: %s is not a shipped preset declaration patch\n' "$patch" >&2
        exit 1
      }
    done
    compactionRows=$(yq -r '[.. | select(tag == "!!map") | select(.id? == "compaction-basic")] | length' "$PTC_UP")
    [ "$compactionRows" -eq 1 ] || {
      printf 'dsh local presets: shipped ptc has %s compaction-basic rows, expected exactly 1\n' "$compactionRows" >&2
      exit 1
    }

    yq -n -P '
      load(strenv(MIN_UP)) as $minUp | load(strenv(MIN_EX)) as $minEx | load(strenv(MIN_META)) as $minMeta |
      load(strenv(PTC_UP)) as $ptcUp | load(strenv(PTC_EX)) as $ptcEx | load(strenv(PTC_META)) as $ptcMeta |
      load(strenv(ROUTER_COMP)) as $routerComp | load(strenv(ROUTER_META)) as $routerMeta |
      load(strenv(MYROUTER_COMP)) as $myRouterComp | load(strenv(MYROUTER_META)) as $myRouterMeta |
      ($ptcUp | (.. | select(tag == "!!map") | select(.id? == "compaction-basic")) |= {"id": "blackhole-compact", "name": "./nix-presets/dsh-blackhole/lib/compaction.js"}) as $ptcSwapped |
      ($minEx | (.. | select(tag == "!!map") | .name | select(tag == "!!str") | select(test("^\\./"))) |= ("./nix-presets/" + sub("^\\./"; ""))) as $minExFixed |
      ($ptcEx | (.. | select(tag == "!!map") | .name | select(tag == "!!str") | select(test("^\\./"))) |= ("./nix-presets/" + sub("^\\./"; ""))) as $ptcExFixed |
      ($routerComp | (.. | select(tag == "!!map") | .name | select(tag == "!!str") | select(test("^\\./"))) |= ("./nix-presets/router-standard/" + sub("^\\./"; ""))) as $routerFixed |
      ($myRouterComp | (.. | select(tag == "!!map") | .name | select(tag == "!!str") | select(test("^\\./"))) |= ("./nix-presets/my-router-standard/" + sub("^\\./"; ""))) as $myRouterFixed |
      [
        { "insert": [ { "id": "preset-my-minimal", "name": "@deepseek-ai/dsh-agent-preset", "config": { "id": "my-minimal", "name": $minMeta.name, "description": $minMeta.description, "order": $minMeta.order, "plugins": ($minUp[0].insert[0].config.plugins + $minExFixed) } } ] },
        { "insert": [ { "id": "preset-my-ptc", "name": "@deepseek-ai/dsh-agent-preset", "config": { "id": "my-ptc", "name": $ptcMeta.name, "description": $ptcMeta.description, "order": $ptcMeta.order, "plugins": ($ptcSwapped[0].insert[0].config.plugins + $ptcExFixed) } } ] },
        { "insert": [ { "id": "preset-router-standard", "name": "@deepseek-ai/dsh-agent-preset", "config": { "id": "router-standard", "name": $routerMeta.name, "description": $routerMeta.description, "order": $routerMeta.order, "plugins": $routerFixed } } ] },
        { "insert": [ { "id": "preset-my-router-standard", "name": "@deepseek-ai/dsh-agent-preset", "config": { "id": "my-router-standard", "name": $myRouterMeta.name, "description": $myRouterMeta.description, "order": $myRouterMeta.order, "plugins": $myRouterFixed } } ] }
      ]
    ' > $out
  '';

  # ── 共享的 LLM 路由事实（modules/home/llm-routes/routes.nix）──────────────
  # relay 的 provider 声明（api / key env / compat / reasoning / models 的能力
  # 元数据）pi 侧也要读，故放共享模块——两处各写一份会漂移（2026-09-14 实测：
  # 两侧 relay key 不同，dsh key 对 v4-flash/v4-pro 全部 403）。
  # runinfra 的模型清单只有本模块需要（pi 侧由扩展运行时注册），故 adapter 留在
  # 下面；共享的只有两侧都要的那个 maxTokens 修正。
  llmRoutes = import ../llm-routes/routes.nix { inherit lib; };
  relayRoute = llmRoutes.relay;
  # nvidia-nim adapter 与本文件的 emitter 共用同一套级别枚举
  inherit (llmRoutes) thinkingLevels;

  # relay 路由的 models: 块（YAML，已预缩进到绝对列 10）
  relayModelsYaml = yamlIndent10 (
    lib.concatStringsSep "\n" (lib.concatMap yamlScalarModel relayRoute.models)
  );



  # ---- YAML emitter（dsh patch 层专用）------------------------------------
  # 本 nixpkgs 的 toYAML 是 toJSON 别名（JSON flow 风格，会污染人工可读的 patch
  # 文件）；模型条目结构固定（扁平字段 + 最多二层 map），故手写 block 风格
  # emitter。indented string 的插值行只有首行继承源缩进、后续行原样落到列 0，
  # 所以整块必须预缩进到绝对列位（models: 在列 8 → 条目在列 10）。
  # nvidia-nim adapter 与 relay 路由共用本套规则。
  yamlScalar = v:
    if builtins.isInt v then builtins.toString v
    else if v == true then "true"
    else if v == false then "false"
    else if builtins.match "^[A-Za-z0-9._]+( [A-Za-z0-9._]+)*$" (builtins.toString v) != null
    then builtins.toString v
    else "\"${builtins.replaceStrings [ "\"" ] [ "\\\"" ] (builtins.toString v)}\"";
  yamlIndent10 = s: "          " + lib.replaceStrings [ "\n" ] [ "\n          " ] s;
  yamlScalarModel = m:
    let
      efforts = m.reasoningEfforts or { };
      compat = m.compat or { };
      effortLevels = lib.filter (l: builtins.hasAttr l efforts) thinkingLevels;
      compatKeys = lib.filter (k: builtins.hasAttr k compat) llmRoutes.compatKeys;
    in
    [
      "- id: ${yamlScalar m.id}"
      "  name: ${yamlScalar m.name}"
      "  contextWindow: ${toString m.contextWindow}"
      "  maxTokens: ${toString m.maxTokens}"
      "  input: [${lib.concatMapStringsSep ", " yamlScalar m.input}]"
    ]
    ++ lib.optional (effortLevels != [ ]) "  reasoningEfforts:"
    ++ (lib.map (l: "    ${l}: ${yamlScalar efforts.${l}}") effortLevels)
    ++ lib.optional (compatKeys != [ ]) "  compat:"
    ++ (lib.map (k: "    ${k}: ${yamlScalar compat.${k}}") compatKeys);

  # relay 路由的 provider 级 compat 块（YAML，绝对列位：compat 在列 8、键在列 10，
  # 与 provider 级其他字段对齐）。
  # 缩进规则（实测）：`''` 会剥掉共同缩进，而插值值**原样插入**、不继承源缩进——
  # 所以多行插值块必须自带完整绝对缩进，源里 ${...} 前面的空格只参与公共缩进计算。
  # 与下面 indent10 的模型块同一手法。
  relayCompatYaml = lib.concatStringsSep "\n" (
    [ "        compat:" ]
    ++ lib.map
      (k: "          ${k}: ${yamlScalar relayRoute.compat.${k}}")
      (builtins.attrNames relayRoute.compat)
  );

  # ---- runinfra models adapter -------------------------------------------
  # 单一数据源 = pi 扩展 monotykamary/pi-runinfra-provider（flake input
  # pi-runinfra-provider-src，flake=false 源码树），与 pi 侧扩展安装共用
  # flake.lock 同一 rev。合并管线复刻扩展 index.ts buildModels：
  # base(models.json) → apply patch.json（compat 一层深合并）→ merge
  # custom-models.json（覆盖同 id）。deprecated-models.json 是 pi 运行时的
  # grace-period 概念，不进静态清单。
  #
  # 本 adapter 只服务 dsh：pi 侧 provider 由扩展在运行时注册
  # （stale-while-revalidate），故那些内容不属共享层。两侧共用的只有
  # routes.nix 的 runinfraModelOverrides（同一个输出上限）。
  #
  # 字段映射：thinkingLevelMap → reasoningEfforts（级别枚举一致）；compat 只保留
  # 两侧交集的键；cost 不在 dsh patch schema，丢弃。
  runinfraSrc = inputs.pi-runinfra-provider-src;
  runinfraModels =
    let
      base = lib.importJSON (runinfraSrc + "/models.json");
      patch = lib.importJSON (runinfraSrc + "/patch.json");
      custom = lib.importJSON (runinfraSrc + "/custom-models.json");

      applyPatch = model: p:
        model
        // lib.optionalAttrs (p ? name) { name = p.name; }
        // lib.optionalAttrs (p ? reasoning) { reasoning = p.reasoning; }
        // lib.optionalAttrs (p ? input) { input = p.input; }
        // lib.optionalAttrs (p ? contextWindow) { contextWindow = p.contextWindow; }
        // lib.optionalAttrs (p ? maxTokens) { maxTokens = p.maxTokens; }
        // lib.optionalAttrs (p ? thinkingLevelMap) { thinkingLevelMap = p.thinkingLevelMap; }
        // lib.optionalAttrs (p ? compat) { compat = (model.compat or { }) // p.compat; };

      applyTo = m: if (builtins.hasAttr m.id patch) then applyPatch m (patch.${m.id}) else m;

      # 网关已上线但扩展内置 catalog 尚未注册的 id。上游一旦注册，knownIds 命中
      # → effectiveExtras 过滤掉本条，自动回归单一数据源。
      # glm-5-3-flash：wire 对齐 zai-coding-cn 的 glm-5.3-flash（thinkingFormat: zai）。
      # nemotron-3-5-lightning-30b：只在扩展的 patch.json（不在 models.json base），
      # 扩展 buildModels 只 patch base 已有 id → pi 靠 live revalidate 补上，dsh
      # 静态清单在此转录 patch.json 的推理元数据。容量取 /v1/models 实测值
      # （2026-09-14：两者 ctx/maxout 均与下表一致，mt 探针均 200）。
      extraModels = [
        {
          id = "glm-5-3-flash";
          name = "GLM-5.3 Flash";
          contextWindow = 1048576;
          maxTokens = 1048576;
          input = [ "text" "image" ];
          thinkingLevelMap = {
            low = "high";
            medium = "high";
            high = "high";
            max = "max";
          };
          compat = {
            thinkingFormat = "zai";
            supportsDeveloperRole = false;
          };
        }
        {
          id = "nemotron-3-5-lightning-30b";
          name = "Nemotron 3.5 Lightning 30B";
          contextWindow = 262144;
          maxTokens = 262144;
          input = [ "text" ];
          thinkingLevelMap = {
            off = "none";
            minimal = "low";
            low = "low";
            medium = "medium";
            high = "xhigh";
            xhigh = "xhigh";
            max = "xhigh";
          };
          compat = {
            thinkingFormat = "openai";
            supportsReasoningEffort = true;
            requiresReasoningContentOnAssistantMessages = true;
            maxTokensField = "max_tokens";
            # runinfra 网关 role 白名单只有 system/user/assistant/tool（developer
            # 实测 400）；supportsStore 与 base models.json 其余模型一致。
            supportsDeveloperRole = false;
            supportsStore = false;
          };
        }
      ];

      orderedBase = lib.map applyTo base;
      orderedCustom = lib.map applyTo custom;
      knownIds = map (m: m.id) (orderedBase ++ orderedCustom);
      effectiveExtras = lib.filter (m: !(lib.elem m.id knownIds)) extraModels;
      orderedRaw = orderedBase ++ orderedCustom ++ effectiveExtras;
      orderedIds = lib.unique (map (m: m.id) orderedRaw);
      idMap = lib.listToAttrs (map (m: {
        name = m.id;
        value = m;
      }) orderedRaw);

      toDshModel = m:
        let
          compat = lib.filterAttrs (n: _: lib.elem n llmRoutes.compatKeys) (m.compat or { });
          efforts = lib.filterAttrs (l: _: lib.elem l thinkingLevels) (m.thinkingLevelMap or { });
          hasThinking = (lib.filter (l: l != "off" && builtins.hasAttr l efforts) thinkingLevels) != [ ];
        in
        {
          id = m.id;
          name = m.name or m.id;
          contextWindow = m.contextWindow;
          maxTokens = m.maxTokens;
          input = m.input or [ "text" ];
        }
        // lib.optionalAttrs hasThinking { reasoningEfforts = efforts; }
        // lib.optionalAttrs (compat != { }) { inherit compat; };
    in
    assert lib.assertMsg (lib.length orderedIds > 0) "runinfra: 扩展模型清单为空";
    lib.map (id: toDshModel idMap.${id}) orderedIds;

  # 叠加共享的两侧修正（见 routes.nix 的 runinfraModelOverrides）
  runinfraModelsFinal = lib.map (
    m: m // (llmRoutes.runinfraModelOverrides.${m.id} or { })
  ) runinfraModels;
  runinfraModelsYaml = yamlIndent10 (
    lib.concatStringsSep "\n" (lib.concatMap yamlScalarModel runinfraModelsFinal)
  );

  # runinfra 路由的接入事实。pi 侧不读这些（provider 由扩展运行时注册），
  # 故不属共享层；providerPatch 与 autosync 行都从这里取，避免两者分叉。
  runinfraRoute = {
    name = "runinfra";
    displayName = "RunInfra";
    api = "openai-completions";
    baseURL = "https://api.runinfra.ai/v1";
    apiKeyEnv = "RUNINFRA_GATEWAY_KEY";
  };

  # ---- nvidia-nim adapter ------------------------------------------------
  # 模型清单来源：data/nvidia-nim-models.json —— 从 pi-nvidia-nim@1.1.23（rev
  # dca7731，JSON 内 upstream 字段）转录。与 runinfra 不同，该扩展没有静态
  # models.json（运行时 fetch /v1/models live discovery），故 dsh 侧取策展的
  # FEATURED_MODELS 快照；pi 运行时发现的 100+ 模型不在 dsh（dsh 注册表是静态
  # 清单，无 live discovery）。thinking 经 dsh chatTemplateKwargs 的 $var 表达
  # （pi-ai resolveChatTemplateKwargValue 同一求值路径，语义已对照 store 内
  # pi-ai dist/api/openai-completions.js 实测）。同步：升级 pi-nvidia-nim npm
  # 版本 → 按新 rev 重新生成 JSON（映射规则见 JSON 内 upstream.note）→ rebuild。
  nimModelsRaw = (lib.importJSON ./data/nvidia-nim-models.json).models;
  # name 已在生成 JSON 时按扩展 makeDisplayName 规则预计算（本 nixpkgs 无
  # lib.splitOn，不在 nix 侧重复实现字符串拆分）。
  # flow-map 递归渲染（chatTemplateKwargs 内嵌一层 $var 对象）
  # 注意：lambda 体内的字符串不能在另一个 ${...} 插值上下文内再开 ${}
  #（Nix 字符串插值是词法嵌套禁止的），故逐键构造先提到独立字符串
  nimYamlVal = v:
    if v == null then "null"
    else if v == true then "true"
    else if v == false then "false"
    else if builtins.isAttrs v
    then let
      pairs = lib.map (k: "${k}: ${nimYamlVal (lib.getAttr k v)}") (builtins.attrNames v);
    in "{${lib.concatStringsSep ", " pairs}}"
    else yamlScalar v;
  nimModelYaml = m:
    let
      # 扩展 buildModelEntry 的默认 compat：NIM 对 developer role +
      # chat_template_kwargs 组合会 500，故全量关闭；max_tokens 字段名更安全。
      # supportsReasoningEffort 默认 false（effort 走 chatTemplateKwargs $var），
      # kimi 例外（JSON 内覆盖为 true，走顶层 reasoning_effort）。
      compat = { supportsDeveloperRole = false; supportsReasoningEffort = false; maxTokensField = "max_tokens"; }
        // (m.compat or {});
      effortPairs = lib.map (l: "${l}: ${nimYamlVal (lib.getAttr l m.reasoningEfforts)}")
        (lib.filter (l: builtins.hasAttr l (m.reasoningEfforts or {})) thinkingLevels);
    in
    [
      "- id: ${yamlScalar m.id}"
      "  name: ${yamlScalar m.name}"
      "  contextWindow: ${toString m.contextWindow}"
      "  maxTokens: ${toString m.maxTokens}"
      "  input: [${lib.concatMapStringsSep ", " yamlScalar m.input}]"
    ]
    ++ lib.optional (m ? reasoningEfforts) "  reasoningEfforts: {${lib.concatStringsSep ", " effortPairs}}"
    ++ [ "  compat: ${nimYamlVal compat}" ];
  nimModelsYaml = yamlIndent10 (lib.concatStringsSep "\n" (lib.concatMap nimModelYaml nimModelsRaw));

  # CodeBuddy Code CLI（Linux）实际写登录态的文件。dsh-codebuddy-cli 自带的
  # 默认探测是 ~/.config/CodeBuddyExtension/Data/Public/auth（插件
  # src/auth.ts 的 defaultAuthDirCandidates，作者自述 Linux 未实测），而 CLI
  # 2.148.0 在本机写的是 ~/.local/share/...（实测依据见 providerPatch 里
  # llm-codebuddy-cli 行注释），所以要在 patch 层显式给 authFile。
  codebuddyAuthFile = "${config.home.homeDirectory}/.local/share/CodeBuddyExtension/Data/Public/auth/Tencent-Cloud.coding-copilot.info";

  # 静态 patch 层：cordis.patch.yml 只被 dsh 只读加载（从不写回），
  # 所以可以安全地由 nix 托管（软链接到 store）。provider 模型路由放这里。
  providerPatch = pkgs.writeText "dsh-cordis.patch.yml" ''
    - id: llm-pi-ai
      config:
        providers:
          # 官方 api.deepseek.com 不在此声明：web profile 内置第一方 llm-deepseek
          # 插件已注册 deepseek-official（显示名 DeepSeek，同样读 DEEPSEEK_API_KEY，
          # 模型更全——含 vision-exp 与文件上传直传）。之前这里配置的 pi-ai catalog
          # deepseek 路由与之完全重复，导致模型选择器同时出现 DeepSeek（官方）和
          # deepseek（catalog id 兜底名）两项；已移除。dsh-web-search-deepseek
          # 也只认 deepseek-official，不受影响。
          # deepseek-relay 路由 = 企业 relay（与官方 DeepSeek 分开；key 走 clan
          # vars deepseek-relay/api-key、baseURL 复用 openai-relay/base-url，
          # 渲染进 dsh.env 的 DEEPSEEK_RELAY_* 独立 env，不影响原 OPENAI_API_KEY）。
          # 非 catalog 路由：pi-ai 没有它的任何内置条目，故 models 条目的能力
          # 元数据只能显式声明。
          # 路由事实（apiKeyEnv / compat / reasoning / models 的能力元数据）全部
          # 来自 modules/home/llm-routes/routes.nix 的单一来源，此处只做 YAML 传输；
          # pi 侧从同一份源渲染 models-overlay.json。改模型/改档位只动那一处。
          # 2026-09-14：两边 key 曾分叉（dsh key 对 v4-flash/v4-pro 全部 403，
          # pi key 可访问），现已统一到 clan vars 的同一个 secret，模型集合也只
          # 保留该 key 实际可访问的 deepseek-flash。
          # relay 角色白名单无 developer（实测 400）→ 路由级 supportsDeveloperRole。
          deepseek-relay:
            apiKeyEnv: ${relayRoute.apiKeyEnv}
            displayName: ${relayRoute.displayName}
            api: ${relayRoute.api}
            # baseURL 走运行时 env：pi 的 baseUrl 不支持 env 插值（只能留在 age
            # 密文），dsh 侧则可以，故这里保持 env 引用而非写死端点。
            baseURL: !!js process.env.${relayRoute.baseURLEnv}
    ${relayCompatYaml}
            # 路由级默认思考档。dsh 的 llm-pi-ai 把 profile.reasoning 交给每个
            # 模型当默认值（describableReasoningLevel → defaultEffort），模型
            # 选择器以此为初值；前提是模型自己声明了对应档（见下）。
            reasoning: ${relayRoute.reasoning}
            # 职责划分：本表提供 *能力元数据*（reasoningEfforts/compat/容量），
            # 因为 /v1/models 只给 id；id 集合的增删由
            # dsh-deepseek-relay-autosync 对 /v1/models 同步（scope 限
            # deepseek-*，其余手工条目不受影响）。每条必须显式声明
            # reasoningEfforts，缺失 = 该模型"无推理能力"→ 选择器不显示思考强度。
            models:
    ${relayModelsYaml}
          # opencode-go 是 pi-ai 内置 catalog 路由（OpenCode Zen Go 网关，
          # 含 deepseek-v4-pro/flash、glm-5.2、kimi-k3、qwen3.7 等模型），
          # 认证环境变量 OPENCODE_API_KEY 与 jojo home 注入一致。
          # 2026-08-29 实测：网关 /go/v1/chat/completions 对 catalog 判定为
          # anthropic-messages 的 minimax-m3 / qwen3.7-max 也 200（统一 OpenAI
          # 兼容端）。catalog 是混合 api（anthropic/openai-completions/
          # openai-responses），sharedCatalogApi 返回 undefined，而 dsh schema 只认
          # 路由级 api（request.api ?? base?.api；models 条目不接受 api/baseURL），
          # 故补 catalog 未描述的模型（如 qwen3.8-flash 等，由 dsh-opencode-autosync
          # 自动发现）必须给路由声明 api + baseURL。这会顺带让 catalog 里少数
          # anthropic 模型改走 openai-completions（已验证可用）。
          opencode-go:
            apiKeyEnv: OPENCODE_API_KEY
            api: openai-completions
            baseURL: https://opencode.ai/zen/go/v1
          # openrouter 是 pi-ai 内置 catalog 路由（https://openrouter.ai/api/v1，
          # openai-completions），catalog 内置 276 个模型，无需手工声明 models。
          openrouter:
            apiKeyEnv: OPENROUTER_API_KEY
          # ox-alpha（stealth/ox-alpha）已转正为智谱 GLM-5.3-Flash，走 zai-coding-cn
          # 端点，此 openrouter 独立路由已移除（2026-08-26）。
          # runinfra：openai-completions 网关。路由事实（apiKeyEnv/baseURL/models）
          # 全部来自 modules/home/llm-routes/routes.nix 的单一来源，此处只做 YAML
          # 传输：模型清单由该模块从 pi 扩展源码树（pi-runinfra-provider-src，与
          # pi 侧同一 rev）的 models.json→patch.json→custom-models.json 合并得出。
          # key 与 pi 侧同一个 clan var（runinfra/gateway_key）。
          # 静态清单无 live 通路，网关新模型会落伍；由下方 runinfra-autosync 插件
          # 按 /v1/models 做 reconcile（增删同步，保留既有条目 compat）。
          # 注意 schema：api/baseURL 在 provider 层（models 条目不接受这些字段）；
          # cost 不在 dsh patch schema，渲染器已丢弃。
          runinfra:
            apiKeyEnv: ${runinfraRoute.apiKeyEnv}
            displayName: ${runinfraRoute.displayName}
            api: ${runinfraRoute.api}
            baseURL: ${runinfraRoute.baseURL}
            models:
    ${runinfraModelsYaml}
          # nvidia-nim：NVIDIA NIM 网关（build.nvidia.com）。模型清单转录自
          # pi-nvidia-nim@1.1.23 的 FEATURED_MODELS 策展清单（见上方 adapter
          # 与 data/nvidia-nim-models.json）；key 由 clan vars
          # （nvidia-nim-api-key）管理，渲染进 dsh.env 的 NVIDIA_NIM_API_KEY。
          nvidia-nim:
            apiKeyEnv: NVIDIA_NIM_API_KEY
            displayName: NVIDIA NIM
            api: openai-completions
            baseURL: https://integrate.api.nvidia.com/v1
            models:
    ${nimModelsYaml}
          zai-coding-cn:
            apiKeyEnv: ZAI_CODING_CN_API_KEY
            models:
              # ox-alpha 正式版（Z.ai blog：1M context）。flash 支持图片输入，
              # 不声明 input 时按纯文本模型处理（附件被降级/拒绝）→ 显式列 image。
              # maxTokens 参考 glm-5.3 取 131072，文档未单列 flash 的 max output。
              - id: glm-5.3-flash
                name: GLM-5.3 Flash
                contextWindow: 1000000
                maxTokens: 131072
                input: [text, image]
                reasoningEfforts:
                  low: high
                  medium: high
                  high: high
                  max: max
                compat:
                  thinkingFormat: zai
              - id: glm-5.3
                name: GLM-5.3
                contextWindow: 1000000
                maxTokens: 131072
                reasoningEfforts:
                  low: high
                  medium: high
                  high: high
                  max: max
                compat:
                  thinkingFormat: zai
          # 内置 catalog 路由 openai（gpt 全家族，api=openai-responses）重定向到企业
          # relay 端点。base URL 与 deepseek-relay 同源：clan vars openai-relay/base-url
          # 渲染进 dsh.env 的 DEEPSEEK_RELAY_BASE_URL（同一网关，单一事实来源，换值仍
          # clan vars set zen14 openai-relay/base-url）；认证沿用路由默认 OPENAI_API_KEY。
          # 模型清单保持 catalog 原样，仅以 modelOverrides 钉住 gpt-5.6-sol 的
          # contextWindow（272000 = 上游 pricing tiers 分档边界，防 catalog 漂移）。
          # 注意：modelOverrides 只允许出现在未声明 models 列表的 catalog 路由上，
          # 两者同配会被 dsh 拒载。
          openai:
            baseURL: !!js process.env.DEEPSEEK_RELAY_BASE_URL
            modelOverrides:
              gpt-5.6-sol:
                contextWindow: 272000

    # CodeBuddy 的 llm-codebuddy-cli 行**不在这里**：本文件是 deployment 层
    # （$DSH_HOME/cordis.patch.yml），对**所有** profile 生效，而 llm-codebuddy-cli
    # 这一行由第三方插件 dsh-codebuddy-cli 自带（且只装进 web profile）。0.1.6 起
    # 按 id patch 一个不存在的行会让该 profile 的 `--dump-config` 直接报
    # `patch: entry "llm-codebuddy-cli" not found` 退出（实测；web profile 因为装了
    # 插件才看不出来）。故该行的 config 改放 web profile 自己的 user layer：
    # $DSH_HOME/profiles/web/cordis.patch.yml（见下方 webProfilePatch），
    # 那里 patch 只作用于装了插件的 profile，语义与生命周期都对得上。

    # MCP server 条目：由 modules/home/mcp-servers/servers.nix 统一渲染
    # （pi 侧同一份源生成 ~/.pi/agent/mcp.json）。密钥一律走 !!js
    # process.env.VAR，值由 dsh.env（sops 渲染）注入，本 patch 文件不含明文。
    # 当前 dsh 侧启用 agent-docs / apipost / context7 / figma / github /
    # web-search-prime / zai-mcp-server；chrome-devtools 需 DISPLAY
    # （dsh-web 服务无），仅 pi。
    # headless profile 未装 dsh-mcp-client 时这些条目仅告警跳过
    # （failOnStartupError 默认 false）。
    ${mcpServers.dshPatchEntries}

    # 工具描述花括号清洗（见上方 bracesSanitizePlugin 注释）。waterfall listener
    # 在 next() 之后改写权威 assembly，注册顺序无关；headless 未装包时本条目
    # 加载仅告警跳过。
    - insert:
        - id: mcp-braces-sanitize
          name: dsh-braces-sanitize
          config: {}

    # composer 模型座位替换（见上方 modelSelectPlusPlugin 注释）。行必须在官方
    # ui-model-selection（dsh-web-app bundle 层）之后插入：浏览器端单座位按注册
    # 顺序选举，后注册的本插件胜出。headless 未装包时仅告警跳过。
    - insert:
        - id: ui-model-select-plus
          name: '@local/dsh-model-select-plus'
          config: {}

    # OpenBao LDAP agent 密码注入（见上方 openbaoShellEnvPlugin 注释）：
    # shell-env 注册表 contributor，把 DSH_OPENBAO_LDAP_AGENT_PASSWORD 注入
    # 每次模型 shell 调用（宿主敏感 env 被 scrub，这是官方受信通道）。
    # headless 未装包时仅告警跳过。
    - insert:
        - id: openbao-shell-env
          name: dsh-openbao-shell-env
          config: {}

    # Woodpecker CLI 服务器/令牌注入（见上方 woodpeckerShellEnvPlugin 注释）：
    # 同 openbao 的 shell-env contributor 通道：WOODPECKER_TOKEN 命中敏感名
    # scrub，只能以 DSH_WOODPECKER_* 进入每次模型 shell 调用；BASH_ENV 桥接
    # （dsh-bash-env.sh）自动转回 WOODPECKER_*，CLI 无需任何手动转换。
    # headless 未装包时仅告警跳过。
    - insert:
        - id: woodpecker-shell-env
          name: dsh-woodpecker-shell-env
          config: {}

    # HuggingFace token 注入（见上方 hfShellEnvPlugin 注释）：同 openbao 的
    # shell-env contributor 通道：HF_TOKEN 命中敏感名 scrub，只能以
    # DSH_HF_TOKEN 进入每次模型 shell 调用；BASH_ENV 桥接（dsh-bash-env.sh）
    # 自动转回 HF_TOKEN，hf CLI / transformers 无需任何手动转换。
    # headless 未装包时仅告警跳过。
    - insert:
        - id: hf-shell-env
          name: dsh-hf-shell-env
          config: {}

    # 自动发现 opencode-go 实时模型（见上方 opencodeAutosyncPlugin 注释）。
    # host-only 插件：启动 + 每 intervalMs 拉 opencode.ai Go 档清单，add-only
    # 并入 opencode-go 路由的 models（不删已配置条目）。config 可选覆盖：
    # route / baseURL / api / apiKeyEnv / intervalMs。headless 未装包时仅告警跳过。
    - insert:
        - id: opencode-autosync
          name: dsh-opencode-autosync
          config:
            route: opencode-go
            baseURL: https://opencode.ai/zen/go/v1
            api: openai-completions
            apiKeyEnv: OPENCODE_API_KEY
            intervalMs: 43200000

    # 自动发现 runinfra 实时模型（见上方 runinfraAutosyncPlugin 注释）。
    # host-only 插件：启动 + 每 intervalMs 拉 api.runinfra.ai/v1/models 清单，
    # reconcile（增删同步）runinfra 路由的 models——保留仍在 live 的既有条目
    # （compat/reasoningEfforts/容量）、追加新出现 id（RunInfra 安全默认）、
    # 丢弃网关已下架 id。config 可选覆盖：route / baseURL / api / apiKeyEnv /
    # intervalMs。headless 未装包时仅告警跳过。
    - insert:
        - id: runinfra-autosync
          name: dsh-runinfra-autosync
          config:
            route: ${runinfraRoute.name}
            baseURL: ${runinfraRoute.baseURL}
            api: ${runinfraRoute.api}
            apiKeyEnv: ${runinfraRoute.apiKeyEnv}
            intervalMs: 43200000

    # 自动发现 deepseek-relay 实时模型（见上方 deepseekRelayAutosyncPlugin 注释）。
    # 启动 + 每 intervalMs 拉 relay /v1/models 清单，reconcile deepseek-relay 路由。
    # headless 未装包时仅告警跳过。
    - insert:
        - id: deepseek-relay-autosync
          name: dsh-deepseek-relay-autosync
          config:
            route: ${relayRoute.name}
            # baseURL 走运行时 env：值来自 clan vars openai-relay/base-url
            # （与 providerPatch 的 deepseek-relay.baseURL 同一个 env，单一来源）
            baseURL: !!js process.env.${relayRoute.baseURLEnv}
            api: ${relayRoute.api}
            apiKeyEnv: ${relayRoute.apiKeyEnv}
            intervalMs: 43200000
            # 只管 deepseek-* id：relay 目录还有大量非 DeepSeek 模型，本路由是
            # 手工 curated，不能被 reconcile 塞满（scope 外的条目原样保留）。
            includePrefixes: [deepseek-]
            # /v1/models 只给 id，没有能力元数据。新采纳/待修复的条目用这套
            # 默认档补齐，否则"无 reasoningEfforts"会被判定为无推理能力，
            # 模型选择器里的思考强度整条消失（2026-09-10 改名后即此故障）。
            defaultReasoningEfforts:
              high: high
              max: max

  '';

  # web profile 的 user layer（$DSH_HOME/profiles/web/cordis.patch.yml，dsh 自己把它
  # 描述为 "Your patch layer for this dsh profile"：只读加载、从不回写——实测两个真实
  # profile 至今仍是首次 seed 的 []）。放这里的 patch 行只作用于 web profile，正好匹配
  # "只有该 profile 装了对应插件"的 config 补丁；放进 deployment 层（$DSH_HOME/cordis.patch.yml）
  # 会让没装该插件的 profile patch 不到行而报错。
  #
  # 当前唯一内容 = CodeBuddy authFile：插件 src/auth.ts 的 Linux 默认候选是
  # ~/.config/CodeBuddyExtension/Data/Public/auth；而 CodeBuddy Code CLI 2.148.0 在 Linux
  # 实际写 ~/.local/share/CodeBuddyExtension/Data/Public/auth/Tencent-Cloud.coding-copilot.info
  # （CLI bundle 内 default 分支 join(home,'.local','share','CodeBuddyExtension') +
  # Data/Public/auth + <product>.info；2026-09-10 实测该文件存在、当日 16:47 刷新、结构与
  # 插件 parseCodeBuddyAuth 的 {auth,account} 形状一致）。缺这条时 provider 仍会注册，
  # 但每次请求都抛 "no signed-in CodeBuddy account found"——插件只在 CLI 文件缺位时才
  # 回落到自己那份 $DSH_HOME/.codebuddy-cli-auth.json。运行期优先级：Web 设置卡片的
  # authFile（settings.yaml）> 本行 > 环境变量 CODEBUDDY_CLI_AUTH_FILE > 平台默认。
  # CLI 将来换目录时同步 codebuddyAuthFile。
  # CodeBuddy 的 authFile 行（只对 web profile 生效，理由见上）。
  codebuddyPatchRow = pkgs.writeText "dsh-web-codebuddy-row.yml" ''
    - id: llm-codebuddy-cli
      config:
        authFile: ${codebuddyAuthFile}
  '';

  # web profile 的 user layer = CodeBuddy 行 + 本地 preset 声明行（presetDeclarations，
  # 见上方「本地 Agent Preset」注释）。两者都只对 web profile 有意义：preset 声明需要
  # web-app bundle 的 agent-preset 插件，CodeBuddy 行需要 llm-codebuddy-cli 插件。
  # 合并顺序 = 声明行在后（preset 声明本身不依赖其它行，顺序仅为可读性）。
  webProfilePatch = pkgs.runCommand "dsh-web-cordis.patch.yml" {
    nativeBuildInputs = [ pkgs.yq-go ];
  } ''
    CODEBUDDY=${codebuddyPatchRow} PRESETS=${presetDeclarations} \
      yq -n 'load(strenv(CODEBUDDY)) + load(strenv(PRESETS))' > $out
  '';

  # dsh 的 baseURL/密钥来自 sops 渲染的 envFile（~/.config/dsh.env →
  # sops-nix 的 secrets.d/<gen>/rendered/dsh.env；/run 是 tmpfs，boot 后须等重新渲染）。
  # boot 时 dsh-web 与 sops-nix 同由 default.target 拉起、彼此无排序，实测 dsh-web 比
  # sops-nix 早 88ms 启动（2026-09-07 09:28:41.068839 vs .069953）→ env 尚未就绪。
  # 就绪由 systemd 保证：dsh-web.service 声明 After/Wants=sops-nix.service（见下方 unit），
  # 本脚本只负责在同一进程里 source 后 exec（exec 让 dsh 取代 bash，PID 不变，
  # Type=simple 语义保持）。不在此处轮询：那是手工重造 systemd ordering，且一旦就绪
  # 判据（某个变量名）与实际配置脱钩，服务会永久起不来。
  dshWebStart = pkgs.writeShellScript "dsh-web-start" ''
    # 防御性清理：第三方插件（曾用的 dsh-web-startup-auth 等）的 pnpm 传递依赖会把
    # @deepseek-ai/dsh-host-webserver@0.1.1-rc.2 等旧版实体目录装进 web profile 的
    # node_modules，遮蔽 kernel 的 0.1.2 版本 → webserver handler 抛异常 → GET / 400
    # （页面打不开）。每次启动前幂等删除，让解析回落到 kernel store；
    # dsh-mcp-client 是显式安装的插件，保留。
    for stale in dsh-host-webserver dsh-cmdline cosmokit schemastery; do
      rm -rf "$HOME/.dsh/profiles/web/node_modules/@deepseek-ai/$stale"
    done

    declare -r env_file=${lib.escapeShellArg cfg.envFile}
    set -a
    . "$env_file"
    set +a
    exec ${lib.getExe dshPackage} web --host ${cfg.web.host} --port ${toString cfg.web.port}${lib.concatMapStrings (h: " --trusted-host ${h}") cfg.web.trustedHosts}
  '';
in
{
  options.${namespace}.modules.dsh = with lib; {
    enable = mkEnableOption "DeepSeek Harness (dsh)";

    web.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Host the dsh web UI as a systemd user service.";
    };
    web.host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind host for the dsh web UI.";
    };
    web.port = mkOption {
      type = types.port;
      default = 3080;
      description = "Listen port for the dsh web UI.";
    };
    web.trustedHosts = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra authorities the /api browser-trust fence accepts (host or host:port). Needed when accessing via a .local name from another machine.";
    };

    plugins.opencodeModels.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install wyouwd1/dsh-opencode-models into the web profile. Provides a
        settings section that live-syncs OpenCode Zen free/go tier model lists
        (covers models missing from the bundled pi-ai catalog, e.g. glm-5.3-flash).
      '';
    };

    # systemd user service 环境极简，必须显式注入；shell 里 source 的 default.env 不会带进来。
    # 注意：不能用 Environment = [ "KEY=${config.sops.placeholder...}" ] —— placeholder 是
    # 求值期的占位符字符串，写入单元后不会被解密。必须走 sops.templates 生成 env 文件，
    # 再由 EnvironmentFile 读入（激活时 sops-nix 把 placeholder 替换为真实值）。
    envFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "EnvironmentFile for the dsh web service (sops template output).";
    };

    # 用深源码构建的 dsh（packages/dsh-src，追 deepseek-harness main）替代
    # llm-agents 打包的 npm 版。默认 false（用 llm-agents 稳定版）；体验最新版
    # 时置 true。llm-agents 更新后改回 false 即回退。
    useDshSource = mkOption {
      type = types.bool;
      default = false;
      description = "Build dsh from the deepseek-harness source tree instead of the llm-agents npm package.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      home.packages = [
        dshPackage
        dshFileOpener
        dshBrowser
      ];

      # 文本/源码文件默认用 emacs（用户默认 editor）打开。dsh-web 服务现带 WAYLAND_DISPLAY
      # （has_display=true），xdg-open 走 mime 查找而非 BROWSER 兜底；而 emacsclient.desktop
      # 的 Exec 是 --create-frame，在无 tty 的服务里报 "could not get terminal name"，故 mime
      # 处理器必须用 no-tty-safe 的 dsh-file-open（内部 emacsclient --eval，需要时在 XWayland
      # :0 上补图形帧）。BROWSER=dsh-file-open 继续保留，作无显示环境的兜底。
      # 注意：本 flake 的 nixpkgs 里 xdg.desktopEntries 已移除 extraConfig、求值即报错
      # （brave/emacs 亦受影响），故用 home.file 直接把 .desktop 写进 $XDG_DATA_HOME/applications/。
      home.file."${config.xdg.dataHome}/applications/dsh-file-open.desktop" = {
        text = ''
          [Desktop Entry]
          Type=Application
          Name=Dsh File Open (Emacs)
          Exec=${dshFileOpener}/bin/dsh-file-open %F
          Terminal=false
          NoDisplay=true
          MimeType=text/plain;text/javascript;application/javascript;application/json;text/x-python;text/markdown;text/x-shellscript;application/x-shellscript;text/x-c;text/x-c++;
        '';
      };
      xdg.mimeApps.defaultApplications = {
        "text/plain" = [ "dsh-file-open.desktop" ];
        "text/javascript" = [ "dsh-file-open.desktop" ];
        "application/javascript" = [ "dsh-file-open.desktop" ];
        "application/json" = [ "dsh-file-open.desktop" ];
        "text/x-python" = [ "dsh-file-open.desktop" ];
        "text/markdown" = [ "dsh-file-open.desktop" ];
      };

      # ── DSH 专用浏览器实例的 .desktop（启动器 dshBrowser 见文件顶部 let）──
      home.file."${config.xdg.dataHome}/applications/dsh-browser.desktop" = {
        text = ''
          [Desktop Entry]
          Type=Application
          Name=DSH (DeepSeek Harness)
          Comment=DeepSeek Harness Web UI，独立浏览器实例，固定在 code 工作区
          Exec=${dshBrowser}/bin/dsh-browser http://${cfg.web.host}:${toString cfg.web.port}
          Icon=brave-browser
          Terminal=false
          Categories=Development;
          StartupWMClass=brave-dsh
        '';
      };

      # 静态配置走 cordis.patch.yml（dsh 只读、应用所有 profile），模型路由声明在这里；
      # settings.yaml 留给 dsh 动态管理（Web UI 的 provider 改动 / onboarding 状态），
      # patch 层是 base，settings 分节按提供方合并覆盖，互不冲突。
      home.file.".dsh/cordis.patch.yml" = {
        source = providerPatch;
        force = true;
      };

      # web profile 的 user layer（见 webProfilePatch 注释）：只对 web profile 生效，
      # 所以"只有 web 装了插件才存在的行"的 config 补丁放这里，不会让 headless/tui 等
      # profile 因 patch 不到行而 `--dump-config` 失败。profile 目录可能尚不存在（首次
      # boot 前）——实测预置本文件不影响 dsh 初始化：dsh 只补它缺的 seed 文件，保留本文件。
      home.file.".dsh/profiles/web/cordis.patch.yml" = {
        source = webProfilePatch;
        force = true;
      };

      # 模型 bash 调用的受信 env 自动桥接：dsh 子进程 env 构建擦除敏感名
      # （scrubbedParentEnv 的 KEY|PASSWORD|SECRET|TOKEN），而 shell-env 受信
      # 通道只允许 DSH_* 前缀，所以 woodpecker-cli 认的 WOODPECKER_* 与
      # hf CLI / transformers 认的 HF_TOKEN 不可能出现在模型 shell。dsh.env
      # 设 BASH_ENV 指向本文件（bash 非交互启动时自动 source），把 shell-env
      # 注入的 DSH_WOODPECKER_* / DSH_HF_TOKEN 条件式转回原名——CLI 开箱即用，
      # 无需 agent 手动转换或 skill 说明；交互 persistent shell 另由 ~/.bashrc
      # 覆盖。条件式保证值缺席（headless/pi）时不覆盖已有同名 env。
      #
      # 同一入口还负责 NO_PROXY 方括号清洗（见下方注释）：dsh-http-proxy 的
      # proxyEnvironmentForChild 会给每个子进程的 NO_PROXY 追加 "[::1]"
      # （undici 兼容所需），而 Python httpx 解析不了带方括号的 IPv6，模型
      # shell 里的任何 httpx 工具（hf CLI、transformers 等）构造 client 即崩。
      home.file.".dsh/dsh-bash-env.sh" = {
        text = ''
          # dsh 模型 shell 的受信 env 桥接（dsh.env 的 BASH_ENV 指向；bash 非交互
          # 启动时 source；交互 persistent shell 由 ~/.bashrc 覆盖）。
          # shell-env 注册表只允许 DSH_* 名字，这里把受信值转回 CLI 原名字。
          if [ -n "$DSH_WOODPECKER_SERVER" ]; then
            export WOODPECKER_SERVER="$DSH_WOODPECKER_SERVER"
            export WOODPECKER_TOKEN="$DSH_WOODPECKER_TOKEN"
          fi
          if [ -n "$DSH_HF_TOKEN" ]; then
            export HF_TOKEN="$DSH_HF_TOKEN"
          fi

          # NO_PROXY 方括号 IPv6 清洗：dsh-http-proxy 的 proxyEnvironmentForChild
          # 给子进程 NO_PROXY 合并 "[::1]"（undici 把裸 ::1 读成 host ":" port
          # "1"，故必须带方括号），但 Python httpx 不认方括号形式——构造 client
          # 时生成坏 pattern（all://*[::1]）即抛 InvalidURL: Invalid port ':1]'，
          # 与网络/token 无关。这里抹掉方括号条目、保留裸 ::1（httpx/curl 都
          # 认）；只改被 spawn 的子进程 env，dsh 自身路由策略不受影响。
          _dsh_no_proxy_fix() {
            local name="$1" wrapped
            wrapped="''${!1}"
            [ -n "$wrapped" ] || return 0
            wrapped=",$wrapped,"
            wrapped="''${wrapped//,\[::1\],/,}"
            wrapped="''${wrapped#,}"
            wrapped="''${wrapped%,}"
            printf -v "$name" '%s' "$wrapped"
            export "$name"
          }
          _dsh_no_proxy_fix NO_PROXY
          _dsh_no_proxy_fix no_proxy
          unset -f _dsh_no_proxy_fix
        '';
        force = true;
      };

      # 本地 Agent Preset 的资源目录（0.1.7 声明式模型，见上方「本地 Agent
      # Preset」注释）。声明行放在 web profile 的 user layer，那里的相对说明符
      # ./nix-presets/... 解析到这个目录——它是**一个** store 目录的符号链接，
      # 所以各插件之间、router-*.mjs 与其 router-core-v34.mjs 之间的相对 import
      # 在 realpath 之后仍然成立（旧目录式 preset 逐文件托管踩过的坑不再涉及：
      # 现在没有任何扫描器去 readdir 这个目录，只有 Loader 按 URL 导入）。
      home.file.".dsh/profiles/web/nix-presets" = {
        source = presetAssets;
        force = true;
      };

      # ── DSH skill：woodpecker-ci ────────────────────────────────────────
      # 声明已移到 modules/home/skills（共享 skill 模块）：DSH 的 skill 根仍是
      # ~/.agents/skills（dsh-skill-filesystem rank 500），与 pi / Codex 同一份源；
      # 该模块同时把同一批 skill 投放到 ~/.claude/skills。
    })

    (lib.mkIf cfg.enable {
      # HTTP->SOCKS5 桥接：DSH 官方 dsh-http-proxy 只支持 http/https 代理，
      # 用户提供的是带认证的 socks5://username1:password1@127.0.0.1:10086。
      # 用 gost 在本机开一个 http 代理，转发到该 SOCKS5 上游，DSH 再走这个
      # 本地 http 代理，从而绕开 fake-ip 的 SSRF 误拦。
      # systemd.user.services.dsh-socks-bridge = {
      #   Unit = {
      #     Description = "DSH HTTP-to-SOCKS5 proxy bridge (gost)";
      #     After = [ "network-online.target" ];
      #     Wants = [ "network-online.target" ];
      #   };
      #   Install.WantedBy = [ "default.target" ];
      #   Service = {
      #     Type = "simple";
      #     ExecStart = "${pkgs.gost}/bin/gost -L http://127.0.0.1:10088 -F socks5://username1:password1@127.0.0.1:10086";
      #     Restart = "on-failure";
      #     RestartSec = 5;
      #   };
      # };
    })

    (lib.mkIf (cfg.enable && cfg.web.enable) {
      # 参考 multica-daemon：交给 systemd 托管，脱离 SSH session 生命周期。
      systemd.user.services.dsh-web = {
        Unit = {
          Description = "DeepSeek Harness web UI";
          # sops-nix.service 是 Type=oneshot，负责渲染 secrets.d/<gen>。boot 时它和
          # dsh-web 都由 default.target 并行拉起、彼此无排序（实测 dsh-web 先跑 88ms，
          # 见 dshWebStart 注释）；缺这条依赖 → envFile 未渲染 → 服务无 env 启动即崩。
          # 与 systems/x86_64-linux/zen14 的 aliyun-credentials 同法（after = sops-nix.service）。
          After = [ "network-online.target" "dsh-socks-bridge.service" ]
            ++ lib.optional (cfg.envFile != null) "sops-nix.service";
          Wants = [ "network-online.target" "dsh-socks-bridge.service" ]
            ++ lib.optional (cfg.envFile != null) "sops-nix.service";
        };
        Install.WantedBy = [ "default.target" ];
        Service = {
          Type = "simple";
          # envFile 非空时用 dshWebStart 包装（同进程 source env 后 exec dsh；就绪由上面的
          # After=sops-nix.service 保证），否则直接启动（无 env 依赖）。见 dshWebStart 注释。
          ExecStart = if (cfg.envFile != null) then dshWebStart else
            "${lib.getExe dshPackage} web --host ${cfg.web.host} --port ${toString cfg.web.port}"
            + (lib.concatMapStrings (h: " --trusted-host ${h}") cfg.web.trustedHosts);
          Environment = [
            "PATH=/run/current-system/sw/bin:/etc/profiles/per-user/%u/bin:%h/.local/bin"
            "BROWSER=${dshFileOpener}/bin/dsh-file-open"
          ];
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.plugins.opencodeModels.enable) {
      # dsh 插件 = 往 ~/.dsh/profiles/web 这个 pnpm 项目里加依赖（dsh plugin add 即
      # pnpm add）。不能用 home.file 静态接管 package.json：它是 dsh/pnpm 的活文件
      # （Web UI 装插件也会写它），同 multica config.json 教训，走 activation 幂等安装。
      # 钉在 main HEAD（9f6451a）：v0.1.0 的 settings section 在 dsh 0.1.1-rc.2 下渲染
      # 空白（干净环境冒烟测试复现），main 已修复。首次安装需联网，失败仅告警不阻塞激活。
      home.activation.configureDshOpencodeModels = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="github:wyouwd1/dsh-opencode-models#9f6451ac58885b39d038e085d5475467f2746e97"
        if ! grep -q "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            dshReloadWeb=1
          else
            echo "WARN: dsh-opencode-models 安装失败（离线？），下次重建重试"
          fi
        fi
      '';
    })

    (lib.mkIf cfg.enable {
      # dsh-codebuddy-cli（第三方插件，github:fu827707013/dsh-codebuddy-cli）：
      # 复用本机 CodeBuddy Code CLI（pkgs.${namespace}.codebuddy-code，见
      # modules/home/packages）的登录态，把 CodeBuddy 的模型接进 dsh 的模型
      # 选择器与设置卡片（provider id codebuddy-cli：host 半区注册 provider +
      # 本地 loopback shim，client 半区是 web 平台插件 → 只装 web profile）。
      # 与 dsh-opencode-models 同款 github: 依赖路线：activation 幂等安装，
      # 首次需联网；装成功才置 dshReloadWeb=1（统一在 configureDshReloadWeb
      # 里重启一次 dsh-web）。钉 v0.1.8 的 tag commit；上游更新 = 换下面的 rev
      # （releases: https://github.com/fu827707013/dsh-codebuddy-cli/releases）。
      # 不加 preset 行也不需要 cordis insert 行：插件包自带
      # dsh.bundle.patch（cordis.patch.yml 里的 llm-codebuddy-cli 行），装成
      # 依赖后由 dsh plugin 的 reconcile 自动进 profile 的 bundle 层；它只注册
      # LLM provider / 设置 section / 会话内积分条（src/index.ts 的 apply），
      # 不给 agent 加工具、子代理或命令。
      # 只装 web：client 半区声明 platform: web（TUI/headless 无这一半，插件
      # README 亦警告 TUI 下会导致 dsh 启动崩溃：events is not iterable）。
      # 注意插件自带的 status/doctor CLI（dsh plugin --profile web exec
      # dsh-codebuddy-cli status）在本 profile 下跑不起来：profile 的
      # pnpm-workspace.yaml 是 autoInstallPeers=false（防旧版 @deepseek-ai/*
      # 遮蔽 kernel），它的 @deepseek-ai/* 依赖因此不在 profile node_modules；
      # host 半区不受影响（实测 provider 注册 + 卡片正常），要看登录态直接读
      # 同源路由：curl http://127.0.0.1:<web.port>/plugins/dsh-codebuddy-cli/status
      home.activation.configureDshCodebuddyCli = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="github:fu827707013/dsh-codebuddy-cli#041e932e465bdd0161fc7aeadce6c9fd044039f4"
        if ! grep -q "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            dshReloadWeb=1
          else
            echo "WARN: dsh-codebuddy-cli 安装失败（离线？），下次重建重试"
          fi
        fi
      '';
    })

    (lib.mkIf (cfg.enable && !cfg.useDshSource) {
      # npm 版 dsh 不带 mcp-client，才需要把 @deepseek-ai/dsh-mcp-client 装进 web
      # profile（配合 cordis.patch.yml 里的 mcp-* 插件条目，token 走环境变量）。
      # 源码构建（useDshSource=true）时 kernel 自带该插件，本块不跑——见下方
      # removeStaleDshMcpClient。
      home.activation.configureDshMcpClient = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="@deepseek-ai/dsh-mcp-client@0.0.1-rc.1"
        if ! grep -q "@deepseek-ai/dsh-mcp-client" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            dshReloadWeb=1
          else
            echo "WARN: dsh-mcp-client 安装失败（离线？），下次重建重试"
          fi
        fi
      '';
    })

    (lib.mkIf (cfg.enable && cfg.useDshSource) {
      # 一次性迁移：清掉 web profile 里历史遗留的 npm 版 dsh-mcp-client。
      # 为什么必须清（2026-09-15 实测，两个证据）：
      #   ① profile 本地副本优先于 kernel 链接被解析——在 profile 目录里对
      #      @deepseek-ai/dsh-mcp-client 做 require.resolve，命中的是
      #      profiles/web/node_modules/...（0.0.1-rc.1），不是
      #      profiles/node_modules/...（→ kernel 自带那份）；给本地副本塞一行
      #      console.log 标记后 boot，标记确实打印 = 跑的是旧 npm 副本。
      #   ② 旧守卫是 name-only grep，永远命中 → 即使改 want 的版本也永不重装，
      #      于是升级 dsh 后 MCP 插件仍停在 0.0.1-rc.1（对 0.1.6 只是实测仍可用，
      #      但属双源漂移：内核 0.1.6-alpha.1 那份才是随 flake.lock 走的那份）。
      # 实测 `dsh plugin --profile web remove` 会删掉本地副本并回落 kernel 链接；
      # 删完本块因 grep 不命中自动变 no-op，可长期保留（也为将来切回 npm 版留出
      # configureDshMcpClient 的对称入口）。
      home.activation.removeStaleDshMcpClient = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        if grep -q '"@deepseek-ai/dsh-mcp-client"' "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web remove @deepseek-ai/dsh-mcp-client; then
            echo "dsh: 已移除 web profile 里的 npm 版 dsh-mcp-client（改用 kernel 自带副本）"
            dshReloadWeb=1
          else
            echo "WARN: dsh-mcp-client 移除失败，本地仍是旧 npm 副本（下次重建重试）"
          fi
        fi
      '';
    })

    (lib.mkIf cfg.enable {
      # 花括号清洗插件：源码在 plugins/braces-sanitize/，nix 打包成只读 store path
      # 后以 file: 协议装入 web profile。want 含 store hash，插件内容变更时 spec
      # 随之变化 → grep 不命中 → 自动重装；未变则跳过。
      home.activation.configureDshBracesSanitize = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="file:${bracesSanitizePlugin}"
        if ! grep -qF "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            dshReloadWeb=1
          else
            echo "WARN: dsh-braces-sanitize 安装失败（离线？），下次重建重试"
          fi
        fi
      '';

      # OpenBao LDAP agent 密码注入（见上方 openbaoShellEnvPlugin 注释）：同
      # braces-sanitize 的 file: + store-hash 幂等安装；loader 行在
      # cordis.patch.yml 的 openbao-shell-env insert 条目。装完重启 dsh-web 生效。
      home.activation.configureDshOpenbaoShellEnv = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="file:${openbaoShellEnvPlugin}"
        if ! grep -qF "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            dshReloadWeb=1
          else
            echo "WARN: dsh-openbao-shell-env 安装失败（离线？），下次重建重试"
          fi
        fi
      '';

      # Woodpecker CLI 服务器/令牌注入（见上方 woodpeckerShellEnvPlugin 注释）：
      # 同 openbao-shell-env 的 file: + store-hash 幂等安装；loader 行在
      # cordis.patch.yml 的 woodpecker-shell-env insert 条目。装完重启 dsh-web 生效。
      home.activation.configureDshWoodpeckerShellEnv = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="file:${woodpeckerShellEnvPlugin}"
        if ! grep -qF "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            dshReloadWeb=1
          else
            echo "WARN: dsh-woodpecker-shell-env 安装失败（离线？），下次重建重试"
          fi
        fi
      '';

      # HuggingFace token 注入（见上方 hfShellEnvPlugin 注释）：同
      # woodpecker-shell-env 的 file: + store-hash 幂等安装；loader 行在
      # cordis.patch.yml 的 hf-shell-env insert 条目。装完重启 dsh-web 生效。
      home.activation.configureDshHfShellEnv = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="file:${hfShellEnvPlugin}"
        if ! grep -qF "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            dshReloadWeb=1
          else
            echo "WARN: dsh-hf-shell-env 安装失败（离线？），下次重建重试"
          fi
        fi
      '';

      # 可搜索模型选择器（见上方 modelSelectPlusPlugin 注释）：同 braces-sanitize
      # 的 file: + store-hash 幂等安装；loader 行在 cordis.patch.yml 的
      # ui-model-select-plus insert 条目。装完重启 dsh-web 生效。
      home.activation.configureDshModelSelectPlus = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="file:${modelSelectPlusPlugin}"
        if ! grep -qF "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            dshReloadWeb=1
          else
            echo "WARN: dsh-model-select-plus 安装失败（离线？），下次重建重试"
          fi
        fi
      '';

      # 自动发现 opencode-go 模型（见上方 opencodeAutosyncPlugin 注释）：同
      # model-select-plus 的 file: + store-hash 幂等安装；loader 行在
      # cordis.patch.yml 的 opencode-autosync insert 条目。装完重启 dsh-web 生效。
      home.activation.configureDshOpencodeAutosync = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="file:${opencodeAutosyncPlugin}"
        if ! grep -qF "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            dshReloadWeb=1
          else
            echo "WARN: dsh-opencode-autosync 安装失败（离线？），下次重建重试"
          fi
        fi
      '';

      # 自动发现 runinfra 模型（见上方 runinfraAutosyncPlugin 注释）：同
      # opencode-autosync 的 file: + store-hash 幂等安装；loader 行在
      # cordis.patch.yml 的 runinfra-autosync insert 条目。装完重启 dsh-web 生效。
      home.activation.configureDshRuninfraAutosync = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="file:${runinfraAutosyncPlugin}"
        if ! grep -qF "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            dshReloadWeb=1
          else
            echo "WARN: dsh-runinfra-autosync 安装失败（离线？），下次重建重试"
          fi
        fi
      '';

      # 自动发现 deepseek-relay 模型（见上方 deepseekRelayAutosyncPlugin 注释）：同
      # runinfra-autosync 的 file: + store-hash 幂等安装；loader 行在
      # cordis.patch.yml 的 deepseek-relay-autosync insert 条目。装完重启 dsh-web 生效。
      home.activation.configureDshRelayAutosync = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        pkgJson="$HOME/.dsh/profiles/web/package.json"
        want="file:${deepseekRelayAutosyncPlugin}"
        if ! grep -qF "$want" "$pkgJson" 2>/dev/null; then
          if ${lib.getExe dshPackage} plugin --profile web add "$want"; then
            dshReloadWeb=1
          else
            echo "WARN: dsh-deepseek-relay-autosync 安装失败（离线？），下次重建重试"
          fi
        fi
      '';

      # 所有 configureDsh* 插件步骤共用一个"需要时是否重启 dsh-web"标记 dshReloadWeb：
      # 任何插件真正安装后置 1，全部装完统一在此重启一次。之前每个 configureDsh* 都各
      # 重启一次 dsh-web（310+ task/2G 的 node 进程，停起一次 3~4s，单次激活里被重启 6 次），
      # 这是"最后重启很慢"的主因。entryAfter 列全部 configureDsh*，保证本步在最后一个插件之后、
      # 装完统一只重启一次 dsh-web。also 修复了原幂等守卫：want 用 file:（pnpm 写回的规格）而非
      # file://（永远 grep 不命中 → 每次 switch 都重装+重启）。
      home.activation.configureDshReloadWeb = inputs.home-manager.lib.hm.dag.entryAfter [
        "configureDshOpencodeModels"
        "configureDshCodebuddyCli"
        "configureDshMcpClient"
        "removeStaleDshMcpClient"
        "configureDshBracesSanitize"
        "configureDshOpenbaoShellEnv"
        "configureDshWoodpeckerShellEnv"
        "configureDshHfShellEnv"
        "configureDshModelSelectPlus"
        "configureDshOpencodeAutosync"
        "configureDshRuninfraAutosync"
        "configureDshRelayAutosync"
        # dsh.env 内容变更守卫：必须在 sops-nix 重渲染 dsh.env 之后运行，才能读到新内容。
        "sops-nix"
      ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        # ── dsh.env 内容变更守卫 ──────────────────────────────────────────
        # dsh-web 只在启动时 source dsh.env 一次（dshWebStart 里 set -a; .），运行期间
        # 不重读。sops-nix 每次 switch 都重渲染 dsh.env（并切换 secrets.d/<gen> 目录），
        # 但"只改 dsh.env / 加 secret（如 WOODPECKER_*）"不经过任何 configureDsh* 插件
        # 安装步骤 → 不会置 dshReloadWeb=1 → dsh-web 不重启 → 新 secret 不生效。
        # 这里用内容哈希对比（而非 mtime：每次渲染都换目录、mtime 恒变会误触发），
        # 变了才置 1。首次无记录也置 1 并落基线，保证守卫上线即收敛到与 dsh.env 一致。
        ${lib.optionalString (cfg.envFile != null) ''
        env_file=${lib.escapeShellArg cfg.envFile}
        hash_state="$HOME/.dsh/.dsh-env-hash"
        new_hash="$(${pkgs.coreutils}/bin/sha256sum "$env_file" 2>/dev/null | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
        if [ -n "$new_hash" ]; then
          old_hash="$(${pkgs.coreutils}/bin/cat "$hash_state" 2>/dev/null || true)"
          if [ -z "$old_hash" ] || [ "$new_hash" != "$old_hash" ]; then
            printf '%s\n' "$new_hash" > "$hash_state"
            dshReloadWeb=1
          fi
        fi
        ''}
        if [[ "''${dshReloadWeb:-0}" = "1" ]]; then
          systemctl --user try-restart dsh-web.service 2>/dev/null || true
        fi
      '';

      # ── codebuddy 登录态 / 模型清单可观测性 ─────────────────────────────
      # CodeBuddy 是纯运行时 provider：模型清单由上游
      # copilot.tencent.com/console/enterprises/personal/models 与 agents[cli]
      # 白名单的交集决定，凭据是 CLI 登录产生的 OAuth refresh token（会轮换）。
      # 两者都无法声明式管理——插件即真源，nix 侧只有 authFile 路径与插件 rev。
      # 代价是这套状态对 nix 完全不可见：登录态过期、插件未装、上游改 cli agent
      # 白名单，全都静默。
      # 本步骤只做可观测性（不写任何配置）：激活末尾查插件的同源状态路由
      # （host 半区注册的 /plugins/dsh-codebuddy-cli/status），把登录态与模型
      # 列表打进激活日志。对比：relay/runinfra 有 autosync 插件对 /v1/models
      # 做 reconcile；codebuddy 没有也不需要清单托管，缺的是可见性。
      # 服务未起 / 插件未装 / 未登录 一律只 WARN，不阻塞激活。
      home.activation.checkDshCodebuddyStatus = inputs.home-manager.lib.hm.dag.entryAfter [ "configureDshReloadWeb" ] ''
        export PATH="${userBin}:/run/current-system/sw/bin:$PATH"
        url="http://${cfg.web.host}:${toString cfg.web.port}/plugins/dsh-codebuddy-cli/status"
        status_json="$(${pkgs.curl}/bin/curl -fsS --max-time 10 "$url" 2>/dev/null || true)"
        if [ -z "$status_json" ]; then
          echo "WARN: dsh-codebuddy-cli status 不可达（服务未起或插件未装）：$url"
        else
          state="$(printf '%s' "$status_json" | ${pkgs.jq}/bin/jq -r '.status // "unknown"')"
          models="$(printf '%s' "$status_json" | ${pkgs.jq}/bin/jq -r '[.models[].id] | join(", ")')"
          echo "dsh-codebuddy-cli: status=$state models=[$models]"
          if [ "$state" != "signed-in" ]; then
            echo "WARN: CodeBuddy 未登录（status=$state）；在终端跑 codebuddy 登录后 dsh 侧 provider 才会可用"
          fi
        fi
      '';
    })
  ];
}
