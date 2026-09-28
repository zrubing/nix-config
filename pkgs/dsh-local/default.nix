# 本仓库的 dsh 本地扩展层。
#
# ## 这一层存在的理由
#
# 上游打包仓库（Moraxyc/deepseek-harness.nix）提供 kernel、workspace、官方 bundle
# 以及把插件组织成 bundle 的组合模型。本仓库在此之上还需要四样它没有的东西：
#
#   1. 本地补丁 —— web-auth-bypass（内网免浏览器 token，Host/Origin fence 保留）；
#   2. 本地插件 —— 7 个自研插件 + 4 个 agent preset；
#   3. dsh-tap —— 上游没有这个 bundle，且它自带的 llm-pi-ai 行必须与本仓库的路由表
#      在构建期合成同一行（见 dshTap.nix）；
#   4. MCP 条目 —— 由 modules/home/mcp-servers 的统一源渲染，随部署变化。
#
# 后两项的内容来自 modules/（routes.nix、servers.nix 是它们的单一事实来源），
# 所以由调用方以文本传入 —— pkgs/ 不反向依赖 modules/。
#
# ## 两条 nixpkgs
#
# 用上游自带那份（`inputs.nixpkgs-dsh`）而不是本仓库的 nixos-26.05：bundle 哈希按
# 上游 rev 计算，换 rev 会让 kernel 与全部 bundle 缓存 miss（本地实测 76 个
# derivation 需重建）。overlay 只作用于这一份 pkgs，不进主 pkgs —— 上游 overlay 会
# 包装 fetchPnpmDeps，扩散到无关包上不是我们想要的。
{
  lib,
  inputs,
  system,
  # llm-pi-ai 的 providers 映射（YAML 文本，含 !!js 标量），来自 routes.nix。
  # **不给兜底值**：传空映射会让 dsh-tap 悄悄只剩自带的 codebuddy 一条路由，
  # 本仓库那 7 条凭空消失，是最难查的一类退化。
  llmPiAiProviders,
  # MCP 条目的 cordis insert 行（YAML 文本），来自 modules/home/mcp-servers。
  mcpEntries,
}:

let
  # 上游自带那份 nixpkgs：bundle 哈希按它算，换成本仓库的 nixos-26.05 会让 kernel
  # 与全部 bundle 缓存 miss（本地实测 76 个 derivation 需重建）。
  upstreamPkgs = import inputs.deepseek-harness.inputs.nixpkgs {
    inherit system;
    overlays = [ inputs.deepseek-harness.overlays.default ];
  };

  inherit (upstreamPkgs.dsh) buildDshBundle;
  inherit (buildDshBundle) dshBundleResolver;

  # ── kernel 本地补丁 ─────────────────────────────────────────────────────
  #
  # 为什么改编译产物而不是源码：上游 dsh-workspace 从源码构建整个 monorepo，打源码
  # 补丁意味着放弃 cachix 缓存（本地实测 76 个 derivation 需重建）。本仓库只要改一行
  # 准入判定，那行在编译产物里可精确定位，所以走 post-processing（秒级）。
  # 代价是对上游改写敏感，因此全部用 `--replace-fail`：上游一改这行，构建立刻失败
  # 而不是静默变回「需要 token 登录」。
  #
  # 补丁内容（dsh-client-connection 的 HostConnectionService）：
  #   上游 = 先过 Host/Origin fence，再过浏览器会话 cookie；未持 cookie 一律 401，
  #          索引页也必须走 ?token= 交换。
  #   本地 = 过了 fence 就免 cookie。fence 本身已挡住 DNS rebinding 与跨站
  #          （实测非信任 Host → 401），cookie 这层在内网反代部署里只是登录摩擦。
  kernelPatched =
    let
      version = upstreamPkgs.dsh.dsh-kernel.version;
      rel = "lib/deepseek-harness/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js";
    in
    upstreamPkgs.runCommand "dsh-kernel-patched"
      {
        pname = "dsh-kernel";
        inherit version;
        nativeBuildInputs = [ upstreamPkgs.gnused ];
        # kernel 的 passthru 里带着 runtimeDeps 与 composedBundles —— dsh 装配包读它们
        # 算 PATH 与层序，丢了就 "attribute 'runtimeDeps' missing"。
        passthru = upstreamPkgs.dsh.dsh-kernel.passthru;
      }
      ''
        cp -r --no-preserve=mode ${upstreamPkgs.dsh.dsh-kernel} $out
        chmod -R u+w $out

        f="$out/${rel}"
        [ -f "$f" ] || {
          printf 'dsh-local: kernel layout changed, missing %s\n' ${rel} >&2
          exit 1
        }

        substituteInPlace "$f" \
          --replace-fail \
          'return this.browserAuth.isAuthenticated(request) ? void 0 : 401;' \
          'return void 0;'

        substituteInPlace "$f" \
          --replace-fail \
          'return this.browserAuth.authorizeIndex(request, response);' \
          'return isTrustedApiRequest(request, this.trustedHosts) || this.browserAuth.authorizeIndex(request, response);'
      '';

  # bundle 的 node_modules 是指向 kernel node_modules 的软链，装配包的 nodeModules
  # 又是 kernel + bundle 的 symlinkJoin —— kernel 一换，引用它的每一层都得跟着换，
  # 否则软链指回未打补丁的那份。
  rebind = pkg: pkg.override { dsh-kernel = kernelPatched; };

  # 上游 bundle 的重绑定版本。作为 `bundles` 传给 dsh：dsh 的
  # `defaultBundles ? with bundles; [headless web-app]` 与内部的 profiles.nix
  # （webBundle/tuiBundle/headlessBundle）都从这个参数取值，所以一次覆盖全链生效。
  upstreamBundles = upstreamPkgs.dsh.bundles // {
    base = rebind upstreamPkgs.dsh.bundles.base;
    headless = rebind upstreamPkgs.dsh.bundles.headless;
    web-app = rebind upstreamPkgs.dsh.bundles.web-app;
    tui = rebind upstreamPkgs.dsh.bundles.tui;
  };

  mkBundle = import ./mk-bundle.nix {
    inherit lib dshBundleResolver kernelPatched;
    inherit (upstreamPkgs) stdenvNoCC nodejs-slim;
  };

  pluginsDir = ../../modules/home/dsh/plugins;
  presetsDir = ../../modules/home/dsh/agent-presets;

  # 一个 ESM 文件包装成可被 preset 按名引用的 npm 包。
  mkTool =
    {
      name,
      file,
      description,
    }:
    mkBundle {
      inherit name;
      src = upstreamPkgs.runCommand "${name}-src" { } ''
        mkdir -p $out
        cp ${file} $out/index.js
        cat > $out/package.json <<JSON
        {
          "name": "${name}",
          "version": "0.1.0",
          "description": ${builtins.toJSON description},
          "type": "module",
          "exports": { ".": "./index.js", "./package.json": "./package.json" }
        }
        JSON
      '';
      meta.description = description;
    };

  # 无代码的「声明包」：只承载一组 insert 行，把同构插件的挂载集中在一处。
  mkDeclBundle =
    {
      name,
      patch,
      description,
    }:
    mkBundle {
      inherit name patch;
      src = upstreamPkgs.runCommand "${name}-src" { } ''
        mkdir -p $out
        cat > $out/package.json <<JSON
        {
          "name": "${name}",
          "version": "0.1.0",
          "description": ${builtins.toJSON description},
          "type": "module",
          "private": true
        }
        JSON
      '';
      meta.description = description;
    };

  # pi-blackhole 适配器要 esbuild 打上游纯 TS 核心，单独走自己的 build.nix。
  blackholeAdapter = import (pluginsDir + "/dsh-blackhole/build.nix") {
    inherit lib inputs kernelPatched;
    inherit (upstreamPkgs) pkgs;
  };

  # ── 本地 bundle 集合 ─────────────────────────────────────────────────────
  #
  # ## patch = "" 的 bundle
  #
  # 有些本地包不自己挂顶层行，而是被 preset 的 `plugins` 数组按名字引用
  # （三个 shell-env 实现包、三个 autosync 实现包、两个 tool 包、blackhole）。
  # 它们仍必须是 bundle —— 只有出现在 `dsh.profile.bundles` 里的包才会被 symlinkJoin
  # 进安装的 node_modules，进而才能被名字解析到 —— 但 patch 为空，不产生顶层行。
  # 这与官方 `dsh-tool-bash` 的处境完全相同：包在安装里，挂载与否由 preset 决定。

  # MCP 工具描述里的字面 {{...}} 组会让 dsh-system-prompt 的严格渲染器抛
  # "malformed prompt variable reference" 并失败整轮对话（上游 issue #711）。
  # 本插件挂 system-prompt/assemble waterfall，在 next() 之后把未注册的花括号组换成
  # 全角；已注册变量（model/cwd）保持插值。
  bracesSanitize = mkBundle {
    name = "dsh-braces-sanitize";
    src = pluginsDir + "/braces-sanitize";
    patch = ''
      - insert:
          - id: mcp-braces-sanitize
            name: dsh-braces-sanitize
            config: {}
    '';
    meta.description = "Neutralize unregistered {{...}} groups leaked into the system prompt by MCP tool descriptions";
  };

  mcp = mkDeclBundle {
    name = "dsh-mcp";
    description = "MCP server entries rendered from modules/home/mcp-servers/servers.nix.";
    patch = mcpEntries;
  };

  shellEnv = mkDeclBundle {
    name = "dsh-shell-env";
    description = "Credential injection through the trusted DSH_* shell-env registry (OpenBao / Woodpecker / HuggingFace).";
    patch = ''
      # 宿主 env 里名字命中 /KEY|PASSWORD|SECRET|TOKEN/i 的变量会被 dsh 的 subprocess
      # env 构建刻意擦除；shell-env 注册表是官方受信通道（executor 在 scrub **之后**
      # 注入，模型无法顶掉托管值）。
      - insert:
          - id: openbao-shell-env
            name: dsh-openbao-shell-env
            config: {}
          - id: woodpecker-shell-env
            name: dsh-woodpecker-shell-env
            config: {}
          - id: hf-shell-env
            name: dsh-hf-shell-env
            config: {}
    '';
  };

  openbaoShellEnv = mkBundle {
    name = "dsh-openbao-shell-env";
    src = pluginsDir + "/openbao-shell-env";
    meta.description = "Inject the OpenBao LDAP agent password as DSH_OPENBAO_LDAP_AGENT_PASSWORD";
  };

  woodpeckerShellEnv = mkBundle {
    name = "dsh-woodpecker-shell-env";
    src = pluginsDir + "/woodpecker-shell-env";
    meta.description = "Inject WOODPECKER_SERVER / WOODPECKER_TOKEN as DSH_WOODPECKER_*";
  };

  hfShellEnv = mkBundle {
    name = "dsh-hf-shell-env";
    src = pluginsDir + "/hf-shell-env";
    meta.description = "Inject the HuggingFace token as DSH_HF_TOKEN";
  };

  autosync = mkDeclBundle {
    name = "dsh-autosync";
    description = "Live model discovery for the opencode-go / runinfra / deepseek-relay routes.";
    patch = ''
      # relay / runinfra 的 /v1/models 是权威所以 reconcile（增删同步，保留仍在 live
      # 的既有条目的 compat / reasoningEfforts / 用户修正容量）；opencode-go 是
      # add-only —— pi-ai 的 catalog 是静态清单，reconcile 会把刚发现的模型当 stale 删掉。
      - insert:
          - id: opencode-autosync
            name: dsh-opencode-autosync
            config:
              route: opencode-go
              baseURL: https://opencode.ai/zen/go/v1
              api: openai-completions
              apiKeyEnv: OPENCODE_API_KEY
              intervalMs: 43200000

          - id: runinfra-autosync
            name: dsh-runinfra-autosync
            config:
              route: runinfra
              baseURL: https://api.runinfra.ai/v1
              api: openai-completions
              apiKeyEnv: RUNINFRA_GATEWAY_KEY
              intervalMs: 43200000

          # baseURL 走运行时 env：与 llm-pi-ai 的 deepseek-relay.baseURL 同一变量
          # （clan vars openai-relay/base-url，单一来源）。
          - id: deepseek-relay-autosync
            name: dsh-deepseek-relay-autosync
            config:
              route: deepseek-relay
              baseURL: !!js process.env.DEEPSEEK_RELAY_BASE_URL
              api: openai-completions
              apiKeyEnv: DEEPSEEK_RELAY_API_KEY
              intervalMs: 43200000
              # 只管 deepseek-* id：relay 目录还有大量非 DeepSeek 模型，本路由是手工
              # curated，不该被 reconcile 塞满（scope 外的条目原样保留）。
              includePrefixes: [deepseek-]
              # /v1/models 只给 id，没有能力元数据。新采纳的条目用这套默认档补齐，
              # 否则「无 reasoningEfforts」会被判为无推理能力，模型选择器里的思考强度
              # 整条消失。
              defaultReasoningEfforts:
                high: high
                max: max
    '';
  };

  opencodeAutosync = mkBundle {
    name = "dsh-opencode-autosync";
    src = pluginsDir + "/opencode-autosync";
    meta.description = "Add-only discovery of the opencode.ai Go-tier model list";
  };

  runinfraAutosync = mkBundle {
    name = "dsh-runinfra-autosync";
    src = pluginsDir + "/runinfra-autosync";
    meta.description = "Reconcile the runinfra route against the live /v1/models listing";
  };

  deepseekRelayAutosync = mkBundle {
    name = "dsh-deepseek-relay-autosync";
    src = pluginsDir + "/deepseek-relay-autosync";
    meta.description = "Reconcile the deepseek-relay route against the live /v1/models listing";
  };

  presets = mkBundle {
    name = "dsh-local-presets";
    patch = builtins.readFile presetsPatch;
    src = upstreamPkgs.runCommand "dsh-local-presets-src" { } ''
      mkdir -p $out
      cat > $out/package.json <<'JSON'
      {
        "name": "dsh-local-presets",
        "version": "0.1.0",
        "description": "Local agent presets (my-minimal / my-ptc / router-standard / my-router-standard).",
        "type": "module",
        "private": true
      }
      JSON
    '';
    meta.description = "Local agent presets composed from shipped presets plus local deltas";
  };

  toolProcesses = mkTool {
    name = "dsh-tool-processes";
    file = presetsDir + "/my-minimal/tool-processes.js";
    description = "start_process: spawn a long-running command without blocking the conversation, registering the handle with the host ctx.jobs runtime";
  };

  toolAstGrep = mkTool {
    name = "dsh-tool-ast-grep";
    file = presetsDir + "/my-minimal/tool-ast-grep.js";
    description = "ast_grep: structural search and preview-rewrite over tree-sitter ASTs through the same shell seam as bash";
  };

  # 两份 router preset 的私有文件。它们用 `./router-bootstrap-v34.mjs?v=88` 这类
  # 相对说明符互相引用（查询串是上游的缓存破坏标记），而 preset 的
  # `config.plugins[].name` **不经过** app-boot 的 anchorInsertedPluginNames
  # （那个函数只处理 insert 顶层与 group.config），所以相对路径保持原样、由运行期按
  # profile 目录解析 —— 那正是旧方案需要给每个 profile 投一份 nix-presets 资源目录的
  # 原因。做成包之后行里写包名，由 dsh 的两锚点解析（安装目录优先）找到。
  #
  # 两份 router 的文件同名但内容不同（my-router 的 bootstrap 带本地阶段补丁），
  # 所以是各自的包，presets.nix 的 rewrites 也按文件分组。
  mkRouterTool =
    dir:
    mkBundle {
      name = "dsh-preset-${dir}";
      src = upstreamPkgs.runCommand "dsh-preset-${dir}-src" { } ''
        mkdir -p $out
        cp ${presetsDir + "/${dir}/router-bootstrap-v34.mjs"} $out/router-bootstrap.js
        cp ${presetsDir + "/${dir}/router-core-v34.mjs"} $out/router-core.js
        cp ${presetsDir + "/${dir}/gitbash-executor.mjs"} $out/gitbash-executor.js
        chmod u+w $out/*
        # bootstrap 用相对路径 import 它的 core，重写成同包内路径。
        substituteInPlace $out/router-bootstrap.js \
          --replace-fail "'./router-core-v34.mjs'" "'./router-core.js'"
        cat > $out/package.json <<JSON
        {
          "name": "dsh-preset-${dir}",
          "version": "0.1.0",
          "description": "Private modules of the ${dir} local agent preset.",
          "type": "module",
          "exports": {
            "./bootstrap": "./router-bootstrap.js",
            "./gitbash-executor": "./gitbash-executor.js",
            "./package.json": "./package.json"
          }
        }
        JSON
      '';
      meta.description = "Private modules of the ${dir} local agent preset";
    };

  presetRouterStandard = mkRouterTool "router-standard";
  presetMyRouterStandard = mkRouterTool "my-router-standard";

  blackhole = mkBundle {
    name = "@jojo/dsh-blackhole";
    src = blackholeAdapter;
    runtimeDeps = [ upstreamPkgs.ripgrep ];
    meta.description = "pi-blackhole adapter: deterministic compaction backend, recall tool, observational memory, /blackhole* commands";
  };

  modelSelectPlus = mkBundle {
    name = "@local/dsh-model-select-plus";
    src = pluginsDir + "/model-select-plus";
    patch = ''
      # 只进 web profile：装进 TUI/headless 会因为解析不到客户端半区而崩溃
      # （2026-09-28 实测：dsh-tui 启动日志里的 "failed to import"）。
      - insert:
          - id: ui-model-select-plus
            name: '@local/dsh-model-select-plus'
            config: {}
    '';
    meta.description = "Searchable, provider-prefixed replacement for the composer model seat";
  };

  # preset 声明行里的相对说明符 → 绝对包名，按源文件分组（两份 router preset 用同名
  # 文件却要指向各自的包）。重写后若仍有残留则构建失败 —— 那条行会在运行期以
  # "failed to import" 静默失效。
  rewrites = {
    minimalExtras = {
      "./tool-processes.js" = "dsh-tool-processes";
      "./tool-ast-grep.js" = "dsh-tool-ast-grep";
      "./dsh-blackhole/lib/index.js" = "@jojo/dsh-blackhole";
      "./dsh-blackhole/lib/compaction.js" = "@jojo/dsh-blackhole/compaction";
    };
    ptcExtras = {
      "./tool-processes.js" = "dsh-tool-processes";
      "./tool-ast-grep.js" = "dsh-tool-ast-grep";
      "./dsh-blackhole/lib/index.js" = "@jojo/dsh-blackhole";
      "./dsh-blackhole/lib/compaction.js" = "@jojo/dsh-blackhole/compaction";
    };
    router = {
      "./router-bootstrap-v34.mjs?v=88" = "dsh-preset-router-standard/bootstrap";
      "./gitbash-executor.mjs?v=49" = "dsh-preset-router-standard/gitbash-executor";
    };
    myRouter = {
      "./router-bootstrap-v34.mjs?v=88" = "dsh-preset-my-router-standard/bootstrap";
      "./gitbash-executor.mjs?v=49" = "dsh-preset-my-router-standard/gitbash-executor";
      "./dsh-blackhole/lib/index.js" = "@jojo/dsh-blackhole";
      "./dsh-blackhole/lib/compaction.js" = "@jojo/dsh-blackhole/compaction";
      "./tool-ast-grep.js" = "dsh-tool-ast-grep";
    };
  };

  presetsPatch = import ./presets.nix {
    inherit lib rewrites;
    inherit (upstreamPkgs) pkgs;
    webAppPresetsDir = "${upstreamBundles.web-app}/lib/node_modules/@deepseek-ai/dsh-web-app/presets";
  };

  # 按 profile 装配 dsh。
  #
  # `bundles` 覆盖而非追加：上游 `defaultBundles ? with bundles; [headless web-app]`
  # 与内部 profiles.nix 的 webBundle/tuiBundle/headlessBundle 都从这个参数取值，
  # 所以这里给重绑定过 kernel 的那份，整链才会用上打过补丁的 kernel。
  #
  # profile 的 bundles 列表同时决定三件事：patch 叠加顺序、profile package.json 的
  # 组合清单、以及什么被 symlinkJoin 进安装的 node_modules（通过 composeBundles 走
  # profilesForComposition）。所以本地 bundle 必须出现在某个 profile 的列表里才会被装。
  mkDsh =
    {
      profiles,
      defaultProfile ? null,
      homePatch ? null,
    }:
    upstreamPkgs.dsh.dsh.override {
      bundles = upstreamBundles;
      dsh-kernel = kernelPatched;
      inherit profiles defaultProfile homePatch;
    };

  # dsh-tap：上游没有这个 bundle，且它自带的 llm-pi-ai 行必须与本仓库的路由表在
  # 构建期合成同一行（理由见该文件头部）。
  dshTap = import ./dsh-tap.nix {
    inherit lib llmPiAiProviders;
    inherit (upstreamPkgs) pkgs;
    inherit buildDshBundle kernelPatched;
  };
in
{
  inherit
    upstreamPkgs
    kernelPatched
    upstreamBundles
    mkBundle
    mkDsh
    ;

  # 三条 profile 共用的 host 插件（与前端形态无关）。
  # 顺序 = 安装顺序，不是 patch 顺序（patch 顺序由 profile.bundles 决定）。
  hostBundles = [
    bracesSanitize
    mcp
    shellEnv
    openbaoShellEnv
    woodpeckerShellEnv
    hfShellEnv
    autosync
    opencodeAutosync
    runinfraAutosync
    deepseekRelayAutosync
    presets
    toolProcesses
    toolAstGrep
    presetRouterStandard
    presetMyRouterStandard
    blackhole
    dshTap
  ];

  # web profile 专属（浏览器半区）。
  webBundles = [ modelSelectPlus ];
}
