{
  config,
  lib,
  pkgs,
  inputs,
  namespace,
  ...
}:

# DeepSeek Harness (dsh) 的 home 侧接线。
#
# ## 分层：nix 拥有代码与默认值，dsh 拥有状态
#
#   bundle 层（nix 独占，dsh 只读）   插件、MCP 条目、llm-pi-ai 路由、preset 声明
#   profile 层（dsh 独占，nix 不碰）  运行时状态：设置卡写入、逐模型启停、onboarding
#   home 层（不使用）                 patch 的 config 整块替换，会锁死运行时写入
#
# 本模块不再托管任何 patch 文件、不再在 activation 里跑 `dsh plugin add`、不再需要
# pnpm。插件安装 = profile 的 `dsh.profile.bundles` 列表，在 pkgs/dsh-local 构建期
# 装配进 dsh 安装目录 —— bundle 从**安装锚点**解析（dsh 的 resolveBundleDir），
# 所以 profile 目录零依赖（无 node_modules、无 pnpm-workspace、无 lockfile）。
#
# ## 为什么 profile 的 cordis.patch.yml 完全交给 dsh
#
# 它同时是 dsh 运行时的写入目标（dsh-tap 设置卡、Settings UI 都写它）。旧方案用
# home.file + force 托管它，实测被 dsh 写回成普通文件后互相覆盖：下次 switch 抹掉
# 运行时状态。现在 nix 只声明 bundle，运行时想写什么写什么，两层不争同一行。
#
# ## llm-pi-ai 为什么在 bundle 层
#
# dsh-tap 的运行时把 `llm-pi-ai` 整行当成自己的数据库（目录同步、逐模型启停、
# Trae/Qoder 注册都写这一行）。patch 的 config 是整块替换，所以只要 home 层或
# profile 层还留着一行 llm-pi-ai，它自带的 codebuddy 路由就被覆盖、且此后每次写入
# 都被 config-editor 以 "overridden by a home patch" 拒绝。现在本仓库的路由表在
# **构建期**并进 dsh-tap 自己的 cordis.patch.yml（pkgs/dsh-local/dsh-tap.nix），
# 两边合成同一行、同一层，inherited 里同时有我们的 7 条与它的 codebuddy。
let
  cfg = config.${namespace}.modules.dsh;

  # dsh 包 = 上游 kernel + 本地补丁 + 本地 bundle 装配，全部在 pkgs/dsh-local 里。
  # 传入的两份文本由 modules/ 渲染 —— pkgs/ 不反向依赖 modules/：
  #   llmPiAiProviders —— llm-pi-ai 的 providers 映射（本文件下方由 routes.nix 渲染），
  #                       与 dsh-tap 自带的 codebuddy 行在构建期合并；
  #   mcpEntries       —— MCP 条目的 cordis insert 行（servers.nix 的统一源）。
  dshLocal = import ../../../pkgs/dsh-local {
    inherit lib inputs;
    system = pkgs.stdenv.hostPlatform.system;
    inherit llmPiAiProviders;
    mcpEntries = mcpServers.dshPatchEntries;
  };

  # dsh-tui 的显示偏好覆盖行（关掉开屏鲸鱼与闲置动画，minimal 显式保持 false，
  # 底栏打开权限模式与思考档两个字段）。
  #
  # 为什么从 bundle 原文提取**整个** config 再覆盖目标键：dsh 的补丁语义是整体替换
  # config 而非逐键合并（实测：只写 whale/whaleIdle 会让同行的 provider / fullscreen
  # / terminalImages / effort / modes / preset / workspace / sessionId 全部丢失并退回
  # schema 默认）。从原文提取保证上游改 config 时自动跟随，不会静默漂移。
  #
  # statusBar 的两个字段：
  #   mode     —— 底栏显示当前权限模式（默认 / 计划模式 / 完全访问）。dsh-tui 的默认
  #               是 false。开了也只是"有标记才画"：非基准模式（计划、完全访问）本来
  #               就会显示，这个开关真正开启的是基准「默认」模式的常驻显示 —— 即两种
  #               状态都看得见。
  #   thinking —— 思考档（max 等）。默认 true，这里显式钉住：本行整份 config，不写就
  #               跟上游走；上游若改默认，这里不会静默失声。
  # 键名见 `lib/settings.json` 的 settings 条目（"Show thinking" = statusBar.thinking）；
  # `// {}` 为的是上游把 statusBar 键挪走时仍然合并得出来，而不是往 null 上赋值。
  #
  # 这是显示偏好（非功能开关），所以只进 dsh-tui profile。两者也是设置页字段：改名后
  # 写进 profile 层的 cordis.patch.yml，以那边为准。
  #
  # 产出的是一份**文件**，作为 bundle 的构建输入传下去（mkRowBundle 的 patch）。
  # 不要在这里或调用侧 `builtins.readFile` 它：那是 IFD，会把上游 dsh-tui bundle 的
  # 构建（pnpm + 自检，实测 6 分钟）拖进每一次**求值**（nixos-rebuild / nix eval /
  # 编辑器 LSP），而且它失败时 nix 只报 "Cannot build ... 1 dependency failed"，
  # 没有一个字的 builder 日志（2026-10-15 实测）。
  tuiDisplayRow = pkgs.runCommand "dsh-tui-display-row.yml" {
    nativeBuildInputs = [ pkgs.yq-go ];
  } ''
    yq -n '
      (load("${dshLocal.upstreamBundles.tui}/lib/node_modules/@deepseek-harness-tui/dsh-tui/cordis.patch.yml")
        | [.. | select(tag == "!!map") | select(.id? == "dsh-tui")]
        | .[0].config) as $cfg
      | [ { "id": "dsh-tui", "config": ($cfg | .whale = false | .whaleIdle = false | .minimal = false
          | .statusBar = ((.statusBar // {}) | .thinking = true | .mode = true)) } ]
    ' > $out
  '';

  # 把一组 patch 行包成最小 bundle。
  #
  # 为什么需要它：bundle 的 patch 对它所在的所有 profile 生效，所以「只对某 profile
  # 有意义」的行必须住在一个只被那个 profile 列出的 bundle 里。旧方案靠给每个 profile
  # 目录投一份 patch 文件实现，那是 nix 与 dsh 争同一批文件的根源；现在同一份声明写在
  # bundle 里，各 profile 按名字引用。
  mkRowBundle =
    {
      name,
      patch,
      description,
    }:
    dshLocal.mkBundle {
      inherit name patch;
      src = pkgs.runCommand "${name}-src" { } ''
        mkdir -p $out
        cat > $out/package.json <<JSON
        {
          "name": "${name}",
          "version": "0.1.0",
          "private": true,
          "type": "module"
        }
        JSON
      '';
      meta.description = description;
    };

  tuiDisplayBundle = mkRowBundle {
    name = "dsh-tui-display";
    patch = tuiDisplayRow;
    description = "dsh-tui display preferences (whale / whaleIdle off, minimal off)";
  };

  # headless 关掉 dsh-tap 的 loopback 流桥。
  #
  # 为什么必须关：那个桥是给 web 主聊天用的 localhost HTTP 服务，一旦 bind 成功就会
  # 把一个监听句柄挂进事件循环 —— 而 headless profile 的语义是「回答一个任务然后
  # 退出」。2026-09-29 实测：在没有别的进程占 3901 的环境里
  #   dsh --profile nix-headless --help
  # 永不退出（unshare -rn 隔离网络下 30s 超时；本机因为 dsh-web 已占 3901 拿到
  # EADDRINUSE 才掩盖了这个问题）。
  #
  # 这不是只在构建期出现的问题：dshBundleCheckHook 只是第一个踩到的消费者。
  # 关掉后 headless 的 codebuddy 路由仍可通过 api-key 直连使用，只是不走桥。
  headlessBundle = mkRowBundle {
    name = "dsh-headless-tap";
    patch = dshLocal.patchText "dsh-headless-tap" ''
      - id: dsh-tap
        config:
          bridgeEnabled: false
    '';
    description = "Disable the dsh-tap loopback stream bridge in the headless profile";
  };

  # profile 声明。这里写的是**短名**（web / headless / dsh-tui），上游把它物化成
  # `$DSH_HOME/profiles/nix-<短名>` —— 加前缀是为了永不与手敲 `dsh plugin` 建的
  # profile 撞名。defaultProfile 要用物化后的全名（上游会断言它在 managed 列表里）。
  #
  # `bundles` 同时决定三件事：patch 叠加顺序、profile package.json 的组合清单、
  # 以及什么被 symlinkJoin 进 dsh 安装目录 —— 所以本地 bundle 必须出现在这里才会被装。
  profileNames = {
    web = "nix-web";
    headless = "nix-headless";
    tui = "nix-dsh-tui";
    acp = "nix-acp";
  };

  # web profile 的权限行：宿主任一进程（网页端、dsh-tui-remote、CLI）都用它。
  #
  # 为什么钉在 profile 层而不是导出 DSH_PERMISSION_MODE：base 的两处消费点
  # （sandbox-policy.mode / approval.policy）用环境变量，而 dsh-web 由 systemd 拉起、
  # 环境里没有它 —— 这一行才是"部署即完全访问"的声明处。
  #
  # 默认预设不写：sandbox-policy 一旦是 danger-full-access，dsh-permission-presets 的
  # derive() 就从沙箱模式 + 审批策略推出 danger-full-access（新会话据此写入
  # permission/preset 等三个事件，状态栏与 TUI 的模式指示器读的是它）。补一条
  # presets: 表只会把上游的预设表整块复制一份，与内核漂移。
  #
  # 权限是**用户打算覆盖**的字段（两处 config 都有 volatile 字段），所以补丁行只做
  # seed：设置页写入 profile 的 cordis.patch.yml 后以 profile 层为准，本行不与之争。
  # 两个 bundle 不碰同一行（dsh-tap 只写 llm-pi-ai），顺序因此不影响结果。
  webPermissionBundle = mkRowBundle {
    name = "dsh-web-permission";
    patch = dshLocal.patchText "dsh-web-permission" ''
      - id: sandbox-policy
        config:
          mode: danger-full-access
          workspaceRoot: !!js process.cwd()
      - id: approval
        config:
          policy: never
    '';
    description = "dsh web profile: start in full access (no sandbox, no approvals)";
  };

  # `requiresWeb` / `requiresTui` 不是装饰：上游据此决定往该 profile 的组合里**追加**
  # 官方 web-app / tui bundle，并且若两者都为假就追加 headless。
  # 不声明 requiresWeb 的后果是 web profile 变成 headless 组合（没有前端）；
  # 不声明 requiresTui 的后果是 dsh-tui 在 installCheck 里被当成 headless 跑 `--help`，
  # 而 TUI 会接管终端 → 检查超时失败。
  dshPackage = dshLocal.mkDsh {
    # 不设 `mode`：本仓库用自定义播种器（pkgs/dsh-local 的 mkProfileSeeder）替换了
    # 上游的 dsh-sync-profiles。上游的 managed 会在每次启动抹掉运行时设置，mutable
    # 又让 bundle 清单从此不再更新 —— 两个都不对，所以那个二选一在这里不适用。
    profiles = {
      web = {
        requiresWeb = true;
        bundles = dshLocal.hostBundles ++ dshLocal.webBundles ++ [ webPermissionBundle ];
      };
      headless.bundles = dshLocal.hostBundles ++ [ headlessBundle ];
    } // lib.optionalAttrs cfg.plugins.tui.enable {
      dsh-tui = {
        requiresTui = true;
        bundles = dshLocal.hostBundles ++ [ tuiDisplayBundle ];
      };
    } // lib.optionalAttrs cfg.plugins.acp.enable {
      # ACP 服务端 profile：编辑器（Emacs agent-shell / Zed 等）通过 stdio 驱动它。
      #
      # 为什么要 patch 掉 headless 的两行：上游 profiles.nix 给「既不需要 web 也
      # 不需要 tui」的 profile **追加** dsh-headless（本意是让纯 CLI profile 不落到
      # 交互式入口）。而本 profile 的 app 是 acp-app —— 两个 app 的命令 provider
      # 会同时挂上，谁接这次调用不确定，所以显式关掉 headless 的 startup/runner，
      # 这是「本 profile 由 acp-app 承载」的声明。
      #
      # 权限不在这里写死：base 的 sandbox-policy.mode / approval.policy /
      # permission-presets 默认预设三处都读 DSH_PERMISSION_MODE，由 dsh-acp 的启动器
      # 导出。远程客户端不在此列 —— 它的权限由常驻的 web profile 决定
      # （见 webPermissionBundle）。
      acp = {
        bundles = dshLocal.hostBundles ++ dshLocal.acpBundles;
        patch = [
          {
            id = "headless-startup";
            disabled = true;
          }
          {
            id = "headless-runner";
            disabled = true;
          }
        ];
      };
    };
    # CLI 默认 profile 恒为 web：dsh 的 wrapper 在 argv 里没有 --profile 时会注入
    # 这个值（上游 dsh-seed-wrapper）。服务单元也显式传同一个名字 —— 两者一致，
    # 不会出现 "select a profile only once"（wrapper 见到 --profile 就不再注入）。
    defaultProfile = profileNames.web;
  };

  # 宿主包 shim（见 pkgs/dsh-local 的 mkDshHostPackage）：dsh-tui 上游的默认启动线
  # 是它**自己的入口**（先画界面、后台组 profile）。入口只肯托管"顺着 PATH 上第一个
  # dsh 的 realpath 能找到 @deepseek-ai/dsh 包目录"的宿主；nix 的 dsh 没有那个目录，
  # 会回退 `dsh --profile`（本机实测首帧：入口 0.9~1.6s，回退线 5.7~6.6s）。
  dshHostPackage = dshLocal.mkDshHostPackage dshPackage;

  # 入口本体：取自**装配进 profile 的那份** TUI bundle，与 profile 里的 dsh-tui 行同源。
  tuiHostEntry = "${dshLocal.upstreamBundles.tui}/lib/node_modules/@deepseek-harness-tui/dsh-tui/lib/types/dsh-adapter/host-entry.js";

  # TUI 启动器：显式指定 profile。必须传 `--profile` 而不是靠默认值，因为 CLI 的
  # 默认已固定给 web（服务的需要）。
  #
  # 另：wrapper 会把 sops 渲染的 dsh.env source 进进程环境。dsh 的 cordis.patch.yml
  # 用 `!!js process.env.APIPOST_MCP_TOKEN` 之类取密钥，而交互 shell 里没有这些变量
  # （默认 env 只覆盖 pi/codex 用的那批）→ 表达式求值成 undefined → MCP 条目的
  # headers 变成 {} → 撞 mcp-client 的 schema 校验 → 该条目不激活。
  # 2026-09-28 实测：未 source 时 MCP 条目（agent-docs/apipost/context7/figma）
  # 全部 ValidationError。
  dshTui = pkgs.writeShellScriptBin "dsh-tui" ''
    declare -r env_file=${lib.escapeShellArg (if cfg.envFile != null then cfg.envFile else "/dev/null")}
    if [ -r "$env_file" ]; then
      set -a
      . "$env_file"
      set +a
    fi
    # 落地页（Launchpad）是单行编辑器，不支持粘贴图片：剪贴板里是图片时
    # Ctrl+V 会复用 "no usable wl-paste / xclip / xsel" 文案误报（见
    # dsh-tui 的 Launchpad.js，content.kind === 'image' 分支）。默认跳过
    # 落地页，启动直接进对话页，图片可正常粘贴；要看落地页时
    # `DSH_TUI_NO_LAUNCHPAD=0 dsh-tui` 临时恢复。
    export DSH_TUI_NO_LAUNCHPAD="''${DSH_TUI_NO_LAUNCHPAD:-1}"
    # 默认 full access（不设沙箱、不弹审批）。DSH_PERMISSION_MODE 是上游唯一的部署级
    # 权限开关，下游有三处消费点，所以一个变量就够、且彼此不会错位：
    #   1. tui bundle 的 sandbox-policy.mode；
    #   2. 同 bundle 的 approval.policy（danger-full-access ⇒ never）；
    #   3. dsh-permission-presets 的默认预设推断 —— 新会话据此被写入
    #      permission/preset + sandbox/mode + approval/policy 三个事件。
    # 第 3 点是状态栏显示正确的关键：dsh-tui 的模式指示器只从会话日志 fold，
    # 没有这些事件时会回落到 index 0 的「默认」，与现实不符。
    # 保留 `:-`：dsh.env 或命令行里显式赋值仍可覆盖。Shift+Tab 循环照旧
    # （完全访问 → 默认 → 计划），临时回受限模式不必改配置。
    export DSH_PERMISSION_MODE="''${DSH_PERMISSION_MODE:-danger-full-access}"
    # 启动线分流：dsh 自己的启动期选项仍走 `dsh --profile` —— 入口不重现 --patch /
    # --dump-config* / --from-default-profile（上游 host-contract.js 的
    # HOST_DEVIATIONS.no-overlays 写明 "the launcher passes none"）。只看 `--` 之前
    # 的前缀，其余参数照旧原样透传。
    # DSH_TUI_HOST_ENTRY=0 是上游的逃生门（"恢复原启动方式"），同义实现。
    if [ "''${DSH_TUI_HOST_ENTRY:-1}" = 0 ]; then
      exec ${lib.getExe dshPackage} --profile ${profileNames.tui} "$@"
    fi
    for arg in "$@"; do
      case "$arg" in
        --) break ;;
        --profile|--profile=*|--patch|--patch=*|--from-default-profile|--from-default-profile=*|--dump-config|--dump-default-config|--dump-config-schema|-V|--version)
          exec ${lib.getExe dshPackage} --profile ${profileNames.tui} "$@"
          ;;
      esac
    done
    # 默认线：先把可交互界面挂上终端（首帧 ~1s），DSH 在同一进程里随后组合 ——
    # 插件树、MCP 握手、模型目录同步都落在首帧之后，加载期间可输入草稿。
    # PATH 首位必须是 shim：findHostDsh 认的是 PATH 上第一个 `dsh`。
    # --expose-internals 必需：dsh 的 node-addon-require-builtin 依赖它，缺了入口会以
    # "the installed dsh cannot host this launch" 回退（2026-10-15 实测）。
    export PATH=${dshHostPackage}:$PATH
    export DSH_TUI_PROFILE=${profileNames.tui}
    exec ${lib.getExe dshLocal.upstreamPkgs.nodejs-slim} --expose-internals ${tuiHostEntry} "$@"
  '';

  # 远程模式启动器：客户端只画界面、转发 RPC，内核组合 / 凭据 / MCP 全在常驻的
  # `dsh web` 里。因此这里**不需要** source dsh.env（没有凭据要读），也不设
  # DSH_PERMISSION_MODE（权限由 Host 侧的组合决定，客户端只渲染）。它只需要两件事实：
  #
  #   1. 宿主包目录 —— 客户端库（Cordis / Gateway / Remote 描述符）按设计从**被连接
  #      的安装**解析；`/etc/profiles/.../bin/dsh` 是 seed-wrapper，反解不出包目录，
  #      所以 PATH 上必须有 shim。
  #   2. 已构建的 fork 树 —— 尚未打包成 derivation（见 pkgs/dsh-tui-remote/README.md），
  #      默认指向仓库里的开发副本，运行时可用 DSH_TUI_REMOTE_TREE 覆盖。
  # 打包好的远程客户端（packages/dsh-tui-remote）：源码 + 补丁构建进 store，
  # 不再依赖 .m1 那种手工开发树。
  dshTuiRemotePkg = pkgs.callPackage ../../../packages/dsh-tui-remote { };

  dshTuiRemote = pkgs.writeShellScriptBin "dsh-tui-remote" ''
    export DSH_HOST_PACKAGE=${lib.escapeShellArg (toString dshHostPackage)}
    # findHostDsh() 只看 PATH 上第一个 `dsh`，所以 shim 必须排在最前。
    export PATH="$DSH_HOST_PACKAGE:"$PATH
    export DSH_TUI_REMOTE_URL="''${DSH_TUI_REMOTE_URL:-http://${cfg.web.host}:${toString cfg.web.port}}"
    # 构建产物在 store 里；`.m1` 那种开发树不再被引用。
    export DSH_TUI_REMOTE_TREE="''${DSH_TUI_REMOTE_TREE:-${dshTuiRemotePkg}/libexec}"
    # 与 dshTui 同因：落地页是单行编辑器，粘贴图片会误报；默认直接进对话页。
    export DSH_TUI_NO_LAUNCHPAD="''${DSH_TUI_NO_LAUNCHPAD:-1}"
    # 这里只做 `--model` 的**搬运**：把值放进 DSH_TUI_MODEL 再交出去，不解析它的
    # 形状。解析（provider/model[:effort]）在远程入口一处完成 —— 两处各解析一遍就是
    # 两份规则；而 argv 必须剔除它，否则 TUI 的启动提示词解析会把 "deepseek-relay/
    # deepseek-flash" 当成要发的消息，且 `/rewind` 打印的 resume 命令也不该带上它。
    # `--model p/m` 与 `--model=p/m` 都认（`--` 之后的 argv 原样透传，不拦截）。
    # 裸 `--model` 取下一个 argv，正好是空值时/后面没有 argv 时报错，不做猜测。
    # 优先级：命令行 > DSH_TUI_MODEL（dshTui 同款约定）。
    args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --)
          args+=("$@")
          break
          ;;
        --model)
          if [ "$#" -lt 2 ] || [ -z "$2" ]; then
            echo "dsh-tui-remote: --model 需要 <provider>/<model>[:<effort>] 参数" >&2
            exit 2
          fi
          export DSH_TUI_MODEL="$2"
          shift 2
          ;;
        --model=?*)
          export DSH_TUI_MODEL="''${1#--model=}"
          shift
          ;;
        *)
          args+=("$1")
          shift
          ;;
      esac
    done
    if [ ! -f "$DSH_TUI_REMOTE_TREE/lib/types/dsh-adapter/remote/entry.js" ]; then
      echo "dsh-tui-remote: $DSH_TUI_REMOTE_TREE 里没有远程入口（构建产物不完整？）" >&2
      exit 2
    fi
    exec ${lib.getExe dshLocal.upstreamPkgs.nodejs-slim} --expose-internals \
      "$DSH_TUI_REMOTE_TREE/lib/types/dsh-adapter/remote/entry.js" ''${args[@]+"''${args[@]}"}
  '';

  # 升级 dsh-tui 之后先跑这个：它断言客户端依赖的宿主面（描述符、方法名、事件字段）
  # 一个都没变，比"编译通过"有意义得多。退出码非零即契约漂移。
  dshTuiRemoteVerify = pkgs.writeShellScriptBin "dsh-tui-remote-verify" ''
    export DSH_HOST_PACKAGE=${lib.escapeShellArg (toString dshHostPackage)}
    export PATH="$DSH_HOST_PACKAGE:"$PATH
    export DSH_TUI_REMOTE_TREE="''${DSH_TUI_REMOTE_TREE:-${dshTuiRemotePkg}/libexec}"
    exec ${lib.getExe dshLocal.upstreamPkgs.nodejs-slim} --expose-internals \
      "$DSH_TUI_REMOTE_TREE/lib/types/dsh-adapter/remote/verify.js" \
      "''${1:-http://${cfg.web.host}:${toString cfg.web.port}}"
  '';

  # ACP 服务端启动器：Emacs agent-shell（或 Zed 等）以 `command + params` 的形式
  # spawn 它，之后全部交互走 stdio 上的 ACP JSON-RPC。
  #
  # 为什么必须有这层壳（与 dsh-tui 同因）：模型密钥与 MCP token 都在 dsh.env 里，
  # 而客户端进程的环境里没有 —— 直接 spawn `dsh --profile nix-acp`，第一次
  # session/prompt 就会以 `no API key for provider route "deepseek-official"` 失败。
  #
  # 权限与 TUI 线一致：base 的 sandbox-policy.mode / approval.policy /
  # permission-presets 默认预设三处都读 DSH_PERMISSION_MODE，所以一个 export 就够，
  # 不需要往 profile patch 里抄第二份权限配置。保留 `:-`：客户端显式赋值仍可覆盖。
  dshAcp = pkgs.writeShellScriptBin "dsh-acp" ''
    declare -r env_file=${lib.escapeShellArg (if cfg.envFile != null then cfg.envFile else "/dev/null")}
    if [ -r "$env_file" ]; then
      set -a
      . "$env_file"
      set +a
    fi
    export DSH_PERMISSION_MODE="''${DSH_PERMISSION_MODE:-danger-full-access}"
    exec ${lib.getExe dshPackage} --profile ${profileNames.acp} "$@"
  '';

  # 统一 MCP server 定义（pi / dsh 共用源，见该文件头部注释）：新增或修改
  # server 只改那一个文件；此处把同一份源渲染成 cordis insert 条目，密钥走
  # !!js process.env.VAR（值由 dsh.env 注入），与 pi 侧的 ${VAR} 引用同源。
  mcpServers = import ../mcp-servers/servers.nix {
    inherit lib pkgs namespace;
    homeDirectory = config.home.homeDirectory;
    # godot MCP 需外部常驻编辑器（监听 :6550）才可用，缺了只会反复重连、拖慢
    # 启动 → 做成按需启用（见 servers.nix 的 enabled 开关与下方选项）。
    godotEnabled = cfg.mcp.godot.enable;
  };

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

  # ── 共享的 LLM 路由事实（modules/home/llm-routes/routes.nix）──────────────
  # relay 的 provider 声明（api / key env / compat / reasoning / models 的能力
  # 元数据）pi 侧也要读，故放共享模块——两处各写一份会漂移（2026-09-14 实测：
  # 两侧 relay key 不同，dsh key 对 v4-flash/v4-pro 全部 403）。
  # runinfra 的 seed 清单由本模块从 pi 扩展源码树（flake input）派生，pi 侧改为
  # 读 autosync 发布的 catalog（见下方 adapter 注释），故 adapter 留在下面；
  # 容量不再有本地覆盖——网关 /v1/models 是唯一来源。
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

  # ---- runinfra models adapter（seed，非权威）----------------------------
  # 策划数据来源 = pi 扩展 monotykamary/pi-runinfra-provider 的源码树（flake input
  # pi-runinfra-provider-src）。合并管线复刻其 index.ts buildModels：
  # base(models.json) → apply patch.json（compat 一层深合并）→ merge
  # custom-models.json（覆盖同 id）。deprecated-models.json 是 pi 运行时的
  # grace-period 概念，不进静态清单。
  #
  # 这份清单只是 seed：权威是网关 /v1/models，dsh-autosync/runinfra 首轮
  # reconcile 就会删掉网关不再广告的 id、补上新增 id（容量/价格一律取 listing）。
  # snapshot 之后 pi 不再自己同步——pi 的 provider 扩展读 autosync 发布的
  # ~/.cache/llm/runinfra-models.json，两侧因此只有一份模型清单。
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

  runinfraModelsYaml = yamlIndent10 (
    lib.concatStringsSep "\n" (lib.concatMap yamlScalarModel runinfraModels)
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

  # ── llm-pi-ai 的 providers 映射（本仓库的静态路由表）────────────────────
  # 它曾经是 providerPatch（home 层）里的一行，2026-09-29 迁到这里。原因是
  # dsh-tap 的运行时把 llm-pi-ai 整行当成自己的数据库（目录同步、逐模型启停、
  # Trae/Qoder 与额外 key 型服务商的注册都写这一行）。home 层的 patch 排在
  # profile 层之后且 config 是整块替换，只要它还在 home 层，dsh-tap 的每一次
  # 写入都会被 config-editor 以 "overridden by a home patch" 拒绝，而它自带的
  # codebuddy 路由也会被我们覆盖掉（Trae/Qoder 没有静态路由，它们由
  # host-config.js 在运行期往 profile 层铺，所以更依赖这条写入通路能用）。
  #
  # 现在这份映射在**构建期**被并进 dsh-tap 自己的 cordis.patch.yml
  # （pkgs/dsh-local/dsh-tap.nix 的 postInstall），两边合成同一行、同一层，
  # 于是 inherited 里同时有我们的 7 条与它的 codebuddy，设置卡写回后
  # effective == next，守卫通过，双方都不丢。
  #
  # 单一事实来源不变：路由事实仍来自 modules/home/llm-routes/routes.nix，
  # 这里只做 YAML 传输（含 !!js process.env.* 标量，yq 合并会原样保留）。
  # 三条 profile（web / dsh-tui / headless）都装 dsh-tap，所以这份表在任何
  # profile 都生效——与它当年在 home 层"对所有 profile 生效"的语义等价。
  llmPiAiProviders = pkgs.writeText "dsh-llm-pi-ai-providers.yml" ''
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
          # dsh-autosync/deepseek-relay 对 /v1/models 同步（scope 限
          # deepseek-*，其余手工条目不受影响）。每条必须显式声明
          # reasoningEfforts，缺失 = 该模型"无推理能力"→ 选择器不显示思考强度。
          models:
  ${relayModelsYaml}
        # opencode-go 是 pi-ai 内置 catalog 路由（OpenCode Go 网关，
        # 含 deepseek-v4-pro/flash、glm-5.2、kimi-k3、qwen3.7 等模型），
        # 认证环境变量 OPENCODE_API_KEY 与 jojo home 注入一致。
        # baseURL 用官方文档（opencode.ai/v2/docs/console/go）的规范拼写
        # /inference/go/v1；旧拼写 /zen/go/v1 仍是活的别名（2026-10-14 实测
        # 两者 GET /models 返回同一份 40 条清单，chat/messages 也都有应答）。
        # 另：Go 档 2026-09 起强制 x-opencode-session 会话头，缺了直接 400
        # MissingSessionID（先于鉴权判断）。pi-ai 的 withOpenCodeSessionHeader 只包
        # 在它自己的 catalog provider 上，而本路由**必须**声明 api（见下条），走的是
        # buildProvider 的裸协议工厂，那层包装到不了这里 —— 头由 pkgs/dsh-local
        # 补丁 4 在 streamSimple 调用点按会话 id 补，本文件不写静态头。
        # 静态头的代价：所有会话共用一个亲和桶，实测缓存命中 99.7%→79%、中位延迟
        # 8s→13.5s（DSH discussion #5495），所以不要退回去。
        # 2026-08-29 实测：网关 /go/v1/chat/completions 对 catalog 判定为
        # anthropic-messages 的 minimax-m3 / qwen3.7-max 也 200（统一 OpenAI
        # 兼容端）。catalog 是混合 api（anthropic/openai-completions/
        # openai-responses），sharedCatalogApi 返回 undefined，而 dsh schema 只认
        # 路由级 api（request.api ?? base?.api；models 条目不接受 api/baseURL），
        # 故补 catalog 未描述的模型（如 qwen3.8-flash 等，由 dsh-autosync/opencode
        # 自动发现）必须给路由声明 api + baseURL。这会顺带让 catalog 里少数
        # anthropic 模型改走 openai-completions（已验证可用）。
        opencode-go:
          apiKeyEnv: OPENCODE_API_KEY
          api: openai-completions
          baseURL: https://opencode.ai/inference/go/v1
        # 改本表 route 字段（baseURL/api）时注意：这里只是 seed。运行时生效值是
        # profile 自己的 cordis.patch.yml（Settings 缝的落盘目标），而它排在 bundle
        # 之后应用、且 config 是**整体替换**，所以已存在 profile 的 providers 表会
        # 完全盖住本表（2026-10-14 在一次性 DSH_HOME 上用 marker 值实测确认）。
        # 因此改完这里还要在 dsh 停止时同步改
        # $DSH_HOME/profiles/nix-{dsh-tui,web,headless}/cordis.patch.yml 里的同名字段；
        # 新建 profile 不受影响（其 cordis.patch.yml 是 `[]`，全部值来自 bundle）。
        # 模型清单不受此限：dsh-autosync 按 /v1/models 对账并写回运行时，是活的那份。
        # openrouter 是 pi-ai 内置 catalog 路由（https://openrouter.ai/api/v1，
        # openai-completions），catalog 内置 276 个模型，无需手工声明 models。
        openrouter:
          apiKeyEnv: OPENROUTER_API_KEY
        # ox-alpha（stealth/ox-alpha）已转正为智谱 GLM-5.3-Flash，走 zai-coding-cn
        # 端点，此 openrouter 独立路由已移除（2026-08-26）。
        # runinfra：openai-completions 网关。apiKeyEnv/displayName/api/baseURL 与
        # autosync 行取自本模块的 runinfraRoute（同一处值，避免两行分叉）；
        # 模型清单见上方 adapter（seed）。
        # key 与 pi 侧同一个 clan var（runinfra/gateway_key）。
        # 上表是 seed：dsh-autosync/runinfra 按网关 /v1/models 做 reconcile
        # （增删同步，保留既有条目 compat），并把结果发布成 pi 读的 catalog —
        # 两侧同一个同步器、同一份清单。
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
      default = [ ];
      description = "Extra authorities the /api browser-trust fence accepts (host or host:port). Needed when accessing via a .local name from another machine.";
    };

    # MCP server 的按需开关（定义在 modules/home/mcp-servers/servers.nix 的统一源）。
    mcp.godot.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the Godot editor MCP server. It is not a pure client: a Godot
        editor must already be listening on 127.0.0.1:6550, otherwise every
        dsh boot spends time in reconnect backoff and no tool works. Turn this
        on (and start the editor) only when you actually use it.
      '';
    };

    plugins.tui.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add the ccch1mneyyy/dsh-TUI profile (`dsh-tui`): an interactive terminal
        front end with whale status bar, streaming thoughts, double-Esc rollback
        and a context/TPS bar. It is a separate profile because it is a terminal
        front end and conflicts with the web profile's client half.
      '';
    };

    plugins.acp.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Add the official ACP server profile (`nix-acp`) plus the `dsh-acp`
        launcher, so editor ACP clients (Emacs agent-shell, Zed, ...) can drive
        dsh over stdio JSON-RPC. It is a separate profile because ACP is an
        automation-only surface: no DSH presentation cards, plans, todos,
        terminal views, or session replay.
      '';
    };

    # systemd user service 环境极简，必须显式注入；shell 里 source 的 default.env
    # 不会带进来。注意：不能用 Environment = [ "KEY=${config.sops.placeholder...}" ]
    # —— placeholder 是求值期的占位符字符串，写入单元后不会被解密。必须走
    # sops.templates 生成 env 文件，再由 EnvironmentFile 读入（激活时 sops-nix 把
    # placeholder 替换为真实值）。
    envFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "EnvironmentFile for the dsh web service (sops template output).";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # TUI 启动器只在启用 dsh-tui profile 时投递 —— 它引用的 profile 必须存在，
      # 否则 dsh 会以 "profile does not exist" 失败。
      home.packages =
        [ dshPackage ]
        ++ lib.optional cfg.plugins.tui.enable dshTui
        ++ lib.optional cfg.plugins.tui.enable dshTuiRemote
        ++ lib.optional cfg.plugins.tui.enable dshTuiRemoteVerify
        ++ lib.optional cfg.plugins.acp.enable dshAcp;

      # 文本/源码文件默认用 emacs（用户默认 editor）打开。dsh-web 服务现带
      # WAYLAND_DISPLAY（has_display=true），xdg-open 走 mime 查找而非 BROWSER 兜底；
      # 而 emacsclient.desktop 的 Exec 是 --create-frame，在无 tty 的服务里报
      # "could not get terminal name"，故 mime 处理器必须用 no-tty-safe 的
      # dsh-file-open。BROWSER=dsh-file-open 继续保留，作无显示环境的兜底。
      #
      # 注意：本 flake 的 nixpkgs 里 xdg.desktopEntries 已移除 extraConfig、求值即报错
      # （brave/emacs 亦受影响），故用 home.file 直接把 .desktop 写进
      # $XDG_DATA_HOME/applications/。
      xdg.mimeApps.defaultApplications = {
        "text/plain" = [ "dsh-file-open.desktop" ];
        "text/javascript" = [ "dsh-file-open.desktop" ];
        "application/javascript" = [ "dsh-file-open.desktop" ];
        "application/json" = [ "dsh-file-open.desktop" ];
        "text/x-python" = [ "dsh-file-open.desktop" ];
        "text/markdown" = [ "dsh-file-open.desktop" ];
      };

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

      # 模型 shell 的受信 env 桥接。dsh.env 里 BASH_ENV 指向本文件，非交互
      # `bash -c`（模型每次调 bash 都是这种）启动时自动 source。
      #
      # 为什么需要桥：dsh 只让 DSH_* 名字通过 shell-env 受信通道（原名含 TOKEN 会被
      # subprocess scrub 擦掉），所以 woodpecker/hf 的凭据是以 DSH_WOODPECKER_* /
      # DSH_HF_TOKEN 注入的。这里转回 CLI 认的原名，`woodpecker-cli`、`hf download`
      # 无需 agent 手动 export 即可直接用。
      #
      # NO_PROXY 方括号清洗同在这个文件里：dsh-http-proxy 的 proxyEnvironmentForChild
      # 给子进程的 NO_PROXY 会合并 "[::1]"（undici 把裸 ::1 读成 host ":" port "1"，
      # 所以上游必须带方括号），但 Python httpx 不认方括号形式——构造 client 时生成
      # 坏 pattern（all://*[::1]）即抛 InvalidURL: Invalid port ':1]'，与网络/token
      # 无关。抹掉方括号条目、保留裸 ::1（httpx/curl 都认）；只改被 spawn 的子进程
      # env，dsh 自身的路由策略不受影响。
      home.file.".dsh/dsh-bash-env.sh" = {
        text = ''
          # dsh 模型 shell 的受信 env 桥接（dsh.env 的 BASH_ENV 指向；bash 非交互
          # 启动时 source；交互 persistent shell 由 ~/.bashrc 覆盖）。
          if [ -n "$DSH_WOODPECKER_SERVER" ]; then
            export WOODPECKER_SERVER="$DSH_WOODPECKER_SERVER"
            export WOODPECKER_TOKEN="$DSH_WOODPECKER_TOKEN"
          fi
          if [ -n "$DSH_HF_TOKEN" ]; then
            export HF_TOKEN="$DSH_HF_TOKEN"
          fi

          _dsh_no_proxy_fix() {
            local name="$1" wrapped
            wrapped="''${!1}"
            [ -n "$wrapped" ] || return 0
            wrapped=",$wrapped,"
            wrapped="''${wrapped//,\[::1\],/,}"
            wrapped="''${wrapped#,}"
            wrapped="''${wrapped%%,}"
            printf -v "$name" '%s' "$wrapped"
            export "$name"
          }
          _dsh_no_proxy_fix NO_PROXY
          _dsh_no_proxy_fix no_proxy
          unset -f _dsh_no_proxy_fix
        '';
        force = true;
      };
    })

    (lib.mkIf (cfg.enable && cfg.web.enable) {
      # 参考 multica-daemon：交给 systemd 托管，脱离 SSH session 生命周期。
      systemd.user.services.dsh-web = {
        Unit = {
          Description = "DeepSeek Harness web UI";
          # sops-nix.service 是 Type=oneshot，负责渲染 secrets.d/<gen>。boot 时它和
          # dsh-web 都由 default.target 并行拉起、彼此无排序（实测 dsh-web 先跑 88ms）
          # → 缺这条依赖则 envFile 未渲染 → 服务无 env 启动即崩。
          # 与 systems/x86_64-linux/zen14 的 aliyun-credentials 同法。
          After = [ "network-online.target" ]
            ++ lib.optional (cfg.envFile != null) "sops-nix.service";
          Wants = [ "network-online.target" ]
            ++ lib.optional (cfg.envFile != null) "sops-nix.service";
        };
        Install.WantedBy = [ "default.target" ];
        Service = {
          Type = "simple";
          # argv 里必须**只**有选项，不能有 `web` 位置参数。
          #
          # 上游 0.1.7 的 dsh-seed-profile wrapper 把第一个非 `-`/非 `plugin` 的
          # argv[1] 当作 `dsh <profile>` 简写（见上游 package.nix 的 dshSeedWrapper）。
          # 于是 `dsh web --no-open ...` 被解读成「profile 名叫 web」，同步的是
          # `$DSH_HOME/profiles/web` 这个**未被 nix 物化**的目录，nix 的补丁与本地
          # bundle 一个都不加载。2026-09-28 实测：`dsh web --no-open --port 0`
          # 落地 `profiles/web`，package.json 的 bundles 只有 base + web-app，
          # dsh-tap 加载 0 次。这与旧 wrapper 不同（旧版只有配置文件无 profile 播种，
          # 所以 `web` 位置参数在旧版是合法子命令写法）。
          #
          # 现在统一走 `--profile <物化全名>` 显式指定：wrapper 见到 --profile 就
          # 不再注入默认值，也就不会出现「select a profile only once」。
          ExecStart = "${lib.getExe dshPackage} --profile ${profileNames.web} --no-open --host ${cfg.web.host} --port ${toString cfg.web.port}"
            + (lib.concatMapStrings (h: " --trusted-host ${h}") cfg.web.trustedHosts);
          # systemd 的 envFile 是启动时一次性读取，与 dsh 自身的 env 快照一致 ——
          # 旧方案在 wrapper 里 source 是为了让 !!js process.env.* 在求值期可见，
          # 而 dsh 的 launch environment 本来就取自进程 env，故 EnvironmentFile 足够。
          EnvironmentFile = lib.mkIf (cfg.envFile != null) cfg.envFile;
          Environment = [
            "DSH_HOME=${config.home.homeDirectory}/.dsh"
            "BROWSER=${dshFileOpener}/bin/dsh-file-open"
            # systemd --user 的默认 PATH 来自 PAM（/etc/pam/environment），实测含
            # /etc/profiles/per-user/jojo/bin 与 /run/current-system/sw/bin，所以
            # 模型 shell 的 `ast-grep`、MCP 条目的 `npx` 都能解析到 —— 不需要再显式
            # 注入 PATH。这里把它写成断言性的注释，改动 PATH 相关逻辑时先看这条。
          ];
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    })

    # ── dsh.env 变更守卫 + dsh-tap 状态可观测性 ──────────────────────────────
    (lib.mkIf cfg.enable {
      # dsh-web 只在启动时读一次 envFile（systemd 的 EnvironmentFile），运行期间不重读。
      # sops-nix 每次 switch 都重渲染 dsh.env（并切换 secrets.d/<gen> 目录），但
      # 「只改 dsh.env / 加一个 secret」不改变 dsh-web 单元本身 → systemd 不会重启它
      # → 新 secret 不生效。
      #
      # 这里用**内容哈希**对比而非 mtime：每次渲染都换目录，mtime 恒变会误触发。
      # 变了才置标记，末尾统一 try-restart 一次。首次无记录也触发并落基线，
      # 保证守卫上线即与 dsh.env 收敛。
      #
      # 为什么放在 activation 而不是 unit 的 reloadTrigger：envFile 是 sops 的
      # 运行时产物，它的路径每次 switch 都变，systemd 的路径级触发器表达不了
      # 「内容变化」。
      home.activation.dshEnvGuard = lib.mkIf (cfg.envFile != null) (
        inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          hash_state="$HOME/.dsh/.dsh-env-hash"
          env_file=${lib.escapeShellArg cfg.envFile}
          new_hash="$(${pkgs.coreutils}/bin/sha256sum "$env_file" 2>/dev/null | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
          if [ -n "$new_hash" ]; then
            old_hash="$(${pkgs.coreutils}/bin/cat "$hash_state" 2>/dev/null || true)"
            if [ -z "$old_hash" ] || [ "$new_hash" != "$old_hash" ]; then
              ${pkgs.coreutils}/bin/mkdir -p "$(dirname "$hash_state")"
              printf '%s\n' "$new_hash" > "$hash_state"
              systemctl --user try-restart dsh-web.service 2>/dev/null || true
            fi
          fi
        ''
      );

      # dsh-tap 的三条上游里，CodeBuddy 的模型清单由网关目录决定、凭据是它自己那份
      # ~/.dsh/codebuddy-plugin-auth.json，Trae/Qoder 是订阅额度 OAuth —— 三者都无法
      # 声明式管理（插件即真源，nix 侧只有 rev）。代价是这套状态对 nix 不可见：
      # 登录态过期、桥没起来、目录没同步，全都静默。
      #
      # 本步骤只做可观测性（不写任何配置）：激活末尾查插件自己的状态路由
      # GET /dsh-tap/settings（凭据已脱敏），把桥、登录态、有效模型数打进激活日志。
      # 服务未起 / 插件未装 / 未登录一律只 WARN，不阻塞激活。
      home.activation.checkDshTapStatus = lib.mkIf (cfg.enable && cfg.web.enable) (
        inputs.home-manager.lib.hm.dag.entryAfter [ "dshEnvGuard" ] ''
          url="http://${cfg.web.host}:${toString cfg.web.port}/dsh-tap/settings"
          view="$(${pkgs.curl}/bin/curl -fsS --max-time 10 "$url" 2>/dev/null || true)"
          if [ -z "$view" ]; then
            echo "WARN: dsh-tap 状态不可达（dsh-web 未起或插件未装）：$url"
          else
            ${pkgs.jq}/bin/jq -r '
              "dsh-tap: bridge=\(if .bridge.running then "up:\(.bridge.port)" else "down" end)"
              + " codebuddy=\(if .oauth.signedIn then (if .oauth.needsRelogin then "需重新登录" else "signed-in" end) else "未登录" end)"
              + " models=\(.models.effectiveCount) 目录=\(.models.sync.count // "静态兜底")"
              + " trae=\(if .trae.oauth.signedIn then "signed-in" else "未登录" end)"
              + " qoder=\(if .qoder.oauth.signedIn then "signed-in" else "未登录" end)"
            ' <<<"$view"
            # 主聊天走桥：桥不跑 = 模型选择器里 CodeBuddy/Trae/Qoder 三条上游全不可用
            # （deepseek-relay / opencode-go / runinfra 等不受影响）。
            if [ "$(${pkgs.jq}/bin/jq -r '.bridge.running' <<<"$view")" != "true" ]; then
              echo "WARN: dsh-tap 本地桥未运行（.bridge.lastError = $(${pkgs.jq}/bin/jq -r '.bridge.lastError // "—"' <<<"$view")）；CodeBuddy/Trae/Qoder 主聊天不可用"
            fi
            if [ "$(${pkgs.jq}/bin/jq -r '.oauth.signedIn' <<<"$view")" != "true" ]; then
              echo "WARN: CodeBuddy 未登录；在 dsh Web 的插件设置卡里完成登录后 provider 才可用（dsh-tui 里没有设置卡）"
            fi
          fi
        ''
      );
    })
  ];
}
