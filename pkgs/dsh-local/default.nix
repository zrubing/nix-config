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
  # 补丁内容：
  #
  #   1. dsh-client-connection 的 HostConnectionService
  #      上游 = 先过 Host/Origin fence，再过浏览器会话 cookie；未持 cookie 一律 401，
  #             索引页也必须走 ?token= 交换。
  #      本地 = 过了 fence 就免 cookie。fence 本身已挡住 DNS rebinding 与跨站
  #             （实测非信任 Host → 401），cookie 这层在内网反代部署里只是登录摩擦。
  #
  #      适配记录（0.2.1-alpha.4）：requestRejection 退化成 admit() 的薄包装，判决整体
  #      搬进 admit —— fence（isTrusted）→ 浏览器 cookie → API operator cookie → 401。
  #      本地只删判决尾部，fence 与 disposed 两支照旧（/api 路由与 socket 升级都直接调
  #      admit，删尾部是唯一能同时覆盖两者的位置）。新增的 /connect 换 operator 凭证
  #      那条路由不动：内网部署不用它，改它等于给 authorizeConnect 也开一个口子。
  #
  #      适配记录（0.2.1-alpha.2）：上游给 isAuthenticated / authorizeIndex 各加了
  #      `secure` 参数（由监听器自身协议决定 cookie 是否带 Secure），isTrustedApiRequest
  #      也从 2 参变 4 参 —— 新增 bindHost / protocol 决定监听器绑定地址的接受与默认
  #      端口归一化。替换串必须把监听器自己的 host/protocol 一并传下去：漏掉 bindHost
  #      会让「Host 等于监听器绑定 IP」这一支恒为假（该分支不读 trustedHosts），
  #      漏掉 protocol 会让 https 默认端口按 http 归一化。
  #      authorizeIndex 体内没有现成的 carrier，替换串自己取一次（与 requestRejection 同构）。
  #
  #   2. dsh-config-editor 的 edit：整轮写入跑在编辑器自己的 async scope 里。
  #      上游 = `edit` 的 `run` 闭包在调用者的 async 上下文里执行，而它做的事全是 dsh
  #             自己的引导工作：`reconcileProfilePatches(root, …)`（末句是
  #             `ctx.emit("app-boot/config-reload")`，app-boot:3507）、root include 的
  #             `entry.update(...)`（即守卫里的 `root.fiber.update`）、loader 等待。
  #             dsh-tui 会全局改写 `Fiber.prototype._execute`，把插件回调的**每一个
  #             异步延续**都打上 activation token（host-access.js 自注："Carry an
  #             activation token through every async continuation created by a Cordis
  #             plugin callback"），并守卫组合根的 events.emit / fiber.* 等方法。
  #             于是宿主插件发起的 settings 写入必定撞上
  #               dsh-tui: root.events.emit is unavailable from a plugin activation
  #             （2026-09-29 实测：`edit` 进门第一件事就是
  #             `reconcileProfilePatches(root, beforePatches)`，连无变化的对账都过不去），
  #             随后被 edit 的 catch 写回 before → 一个字节都不落盘
  #             （`~/.dsh/profiles/nix-dsh-tui/cordis.patch.yml` 停在 17 字节模板）。
  #      本地 = 这轮写入是宿主在替调用者改配置，不是调用者在驱动组合根，所以整轮跑在
  #             config-editor 自己的 AsyncResource scope 里，继承来的归因随之消失。
  #             守卫本身一个字节都不动：reload 期间每个插件体的 activation 仍由 dsh-tui
  #             的 runActivation 各自设 token（token.fiber ≠ rootFiber），插件照样被拒。
  #             残留面：reload 期间由 cordis 派发、不经 `_execute` 的插件回调（如
  #             `internal/plugin` 监听器）也会失去继承的归因；这类回调本就不是写配置的
  #             主体，且插件与宿主同进程，守卫是纪律边界而非沙箱，接受。
  #
  #   3. dsh-llm-pi-ai 的 internal/config 监听器：`Config()` 校验前先求值 `!!js`。
  #      上游 = pi-ai 在 `internal/config` waterfall 里注册
  #               const raw = next(); ... const candidate = Config(raw);
  #             loader 的全局 interpolate 监听器在 chain 的**外层**（它把下游结果变换
  #             后再返回），所以下游的 pi-ai 拿到的是 bundle 层原样的
  #             `{__jsExpr:"process.env.DEEPSEEK_RELAY_BASE_URL"}` 对象，而
  #             `dsh-llm-pi-ai` 的 `profile.baseURL` 是 `z.string()`（lib/index.js:1017）
  #             → 抛
  #               $.providers.deepseek-relay.baseURL expected string but got [object Object]
  #             （该消息格式已用 schemastery 单独复现确认，`$` 路径前缀就是它自带的）。
  #             pi-ai 的监听器只在 apply 里注册，而 fiber 的首次配置解析发生在 apply
  #             **之前** → 启动不炸、此后任何一次 reload 必炸。settings 的每次写入都会
  #             触发 reload，所以宿主插件的写入、dsh-tap 的宿主镜像、设置页写入全部
  #             失败，且失败发生在 pre-write reconcile 处，文件一个字节不改
  #             （2026-09-30 01:08 实测 dsh-web 日志：dsh-tap 只写
  #             `providers.codebuddy.models`，报的却是 deepseek-relay 的 baseURL ——
  #             校验覆盖整个命名空间）。
  #      本地 = `Config(interpolate(ctx, raw))`，与 loader 在 `_commitVolatile` 里
  #             "先跑 waterfall、再 resolveConfig" 的既定做法一致。
  #             （曾误判为 config-editor 的 resolveConfig 少了求值；实测那条路径的
  #             waterfall 已经插值，真正看到未插值值的是下游的 pi-ai 监听器。）
  #
  # 补丁 2 / 3 / 4 都是上游 bug 的本地兜法，上游修好后删除即可；`--replace-fail` 会在
  # 上游改写这些行时先炸构建，不会静默退回旧行为。
  kernelPatched =
    let
      version = upstreamPkgs.dsh.dsh-kernel.version;
      rel = "lib/deepseek-harness/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js";
      configEditorRel = "lib/deepseek-harness/node_modules/@deepseek-ai/dsh-config-editor/lib/index.js";
      piAiRel = "lib/deepseek-harness/node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js";

      # admit() 尾部的鉴权判决（alpha.4 起 requestRejection 只是它的薄包装，/api 路由
      # 与 socket 升级都直接调 admit）。整段删掉，只留前面的 fence 与 disposed。
      # 行首两个制表符是 JS 产物自己的缩进：用 "\t" 显式写出，不写字面制表符 ——
      # `''` 字符串的公共缩进只按空格计算，字面制表符会把整段裁剪算错。
      admitAuthTail = lib.concatMapStrings (line: "\t\t${line}\n") [
        ''const secure = this.owner.get("webServer")?.protocol === "https:";''
        ''if (this.browserAuth.isAuthenticated(request, secure)) return { peer: this.browserPeer };''
        ''const id = this.browserAuth.authenticateApi(request, secure);''
        ''const record = id === void 0 ? void 0 : this.peers.get(id);''
        ''return record === void 0 ? { rejection: 401 } : { peer: record.peer };''
      ];
      admitAllowed = "\t\treturn { peer: this.browserPeer };\n";
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
          ${lib.escapeShellArg admitAuthTail} \
          ${lib.escapeShellArg admitAllowed}

        substituteInPlace "$f" \
          --replace-fail \
          'return this.browserAuth.authorizeIndex(request, response, this.ctx.get("webServer")?.protocol === "https:");' \
          'const carrier = this.ctx.get("webServer");
return isTrustedApiRequest(request, this.trustedHosts, carrier?.host, carrier?.protocol ?? "http:") || this.browserAuth.authorizeIndex(request, response, carrier?.protocol === "https:");'

        # ── 补丁 2：dsh-config-editor 的 edit 脱离调用者归因 ─────────────────
        ce="$out/${configEditorRel}"
        [ -f "$ce" ] || {
          printf 'dsh-local: kernel layout changed, missing %s\n' ${configEditorRel} >&2
          exit 1
        }

        # 注入的 JS 续行一律顶格写：nix 缩进字符串的公共缩进由**最短**缩进行决定，
        # 而替换串首行紧跟引号（缩进为 0），所以续行写多少就原样进文件。
        substituteInPlace "$ce" \
          --replace-fail \
          'import { withFileLock, writeFileAtomic } from "@deepseek-ai/dsh-atomic-write";' \
          'import { AsyncResource } from "node:async_hooks";
import { withFileLock, writeFileAtomic } from "@deepseek-ai/dsh-atomic-write";

// LOCAL PATCH (nix-config)：整轮写入跑在编辑器自己的 async scope 里，剥掉继承自
// 调用者的 dsh-tui activation 归因。守卫本身不动：reload 期间每个插件体的 activation
// 仍由 dsh-tui 的 runActivation 各自设 token，插件照样被拒。
// 见 pkgs/dsh-local/default.nix 补丁 2。
const DSH_CONFIG_EDIT_SCOPE = new AsyncResource("dsh-config-edit");'

        substituteInPlace "$ce" \
          --replace-fail \
          'await (hmr === void 0 ? run() : hmr.runExclusive(run));' \
          'await (hmr === void 0 ? DSH_CONFIG_EDIT_SCOPE.runInAsyncScope(run) : hmr.runExclusive(() => DSH_CONFIG_EDIT_SCOPE.runInAsyncScope(run)));'

        # ── 补丁 3：dsh-llm-pi-ai 校验前先求值 !!js ─────────────────────────
        pa="$out/${piAiRel}"
        [ -f "$pa" ] || {
          printf 'dsh-local: kernel layout changed, missing %s\n' ${piAiRel} >&2
          exit 1
        }

        substituteInPlace "$pa" \
          --replace-fail \
          'import z from "@deepseek-ai/schemastery";' \
          'import z from "@deepseek-ai/schemastery";
import { interpolate } from "@deepseek-ai/cordis-plugin-loader";'

        substituteInPlace "$pa" \
          --replace-fail \
          'const candidate = Config(raw);' \
          'const candidate = Config(interpolate(ctx, raw));'

        # ── 补丁 4：dsh-llm-pi-ai 按会话补 OpenCode Go 的 x-opencode-session ──
        # 为什么必须补在适配器里：buildProvider 只在路由**没有**声明 api 时才复用
        # pi-ai 的 catalog provider（opencodeGoProvider 上包着
        # withOpenCodeSessionHeader）；路由一旦声明 api（手写模型清单必须声明，
        # 否则拿不到协议），走的是 PROTOCOLS 裸工厂，那层包装到不了，网关直接
        # 400 MissingSessionID。适配器本来就把 options.sessionId 传给 pi-ai 了，
        # 裸工厂不看它 —— 在唯一的 streamSimple 调用点合并即可。
        # 值取会话 id（session-<uuid>，跨轮次 / resume / 压缩稳定），不用固定兜底。
        # 门控：provider 名以 opencode 开头，或 baseURL 的 host 是 opencode.ai
        # （含子域），其余路由的请求头字节不变。非可见 ASCII 的会话 id 直接不发，
        # 免得 Headers 构造抛 TypeError，把一次正常请求变成硬失败。
        substituteInPlace "$pa" \
          --replace-fail \
          '/** Merge deployment headers while removing case-insensitive attribution collisions. */' \
          '/**
 * LOCAL PATCH (nix-config)：OpenCode Go 网关强制 x-opencode-session，而显式声明
 * api 的路由不经过 pi-ai 的 withOpenCodeSessionHeader。见补丁 4。
 */
function opencodeSessionHeaders(provider, baseURL, sessionId) {
    if (typeof sessionId !== "string" || sessionId.length === 0) return {};
    if (!/^[!-~]+$/.test(sessionId)) return {};
    let host = "";
    try {
        host = new URL(baseURL ?? "").hostname;
    } catch {}
    const viaHost = host === "opencode.ai" || host.endsWith(".opencode.ai");
    const viaProvider = typeof provider === "string" && provider.startsWith("opencode");
    if (!viaHost && !viaProvider) return {};
    return { "x-opencode-session": sessionId };
}
/** Merge deployment headers while removing case-insensitive attribution collisions. */'

        substituteInPlace "$pa" \
          --replace-fail \
          'headers: requestHeaders(profile.headers)' \
          'headers: {
...requestHeaders(profile.headers),
...opencodeSessionHeaders(options.provider, profile.baseURL, options.sessionId)
}'

        # 语法自检：注入的 import / const 一旦位置不对，这里立刻失败，
        # 而不是等运行期在启动路径上抛 SyntaxError。
        ${lib.getExe upstreamPkgs.nodejs-slim} --check "$ce"
        ${lib.getExe upstreamPkgs.nodejs-slim} --check "$pa"
      '';

  # bundle 的 node_modules 是指向 kernel node_modules 的软链，装配包的 nodeModules
  # 又是 kernel + bundle 的 symlinkJoin —— kernel 一换，引用它的每一层都得跟着换，
  # 否则软链指回未打补丁的那份。
  rebind = pkg: pkg.override { dsh-kernel = kernelPatched; };

  # dsh-tui 的 verify 套件默认按 CPU 数开并行（本机 16 路），而它的 TUI 断言用
  # settled() 轮询、非 CI 上限 4s（scripts/lib/term-test.mjs）。16 路并行下
  # verify:rewind-edit 的 40 列变体会超时：同一份产物两次构建分别挂在
  # slash 与 slash+escape，其余 89 个 gate 全过（2026-10-17 实测），是 runner
  # 并发而非功能回归。用上游自己的开关（scripts/run-verify-build.mjs 的
  # DSH_TUI_VERIFY_JOBS）压到 4 路，构建产物本身不受影响。
  capTuiVerifyJobs =
    pkg:
    pkg.overrideAttrs (old: {
      env = (old.env or { }) // {
        DSH_TUI_VERIFY_JOBS = "4";
      };
    });

  # 上游 bundle 的重绑定版本。作为 `bundles` 传给 dsh：dsh 的
  # `defaultBundles ? with bundles; [headless web-app]` 与内部的 profiles.nix
  # （webBundle/tuiBundle/headlessBundle）都从这个参数取值，所以一次覆盖全链生效。
  upstreamBundles = upstreamPkgs.dsh.bundles // {
    base = rebind upstreamPkgs.dsh.bundles.base;
    headless = rebind upstreamPkgs.dsh.bundles.headless;
    web-app = rebind upstreamPkgs.dsh.bundles.web-app;
    tui = capTuiVerifyJobs (rebind upstreamPkgs.dsh.bundles.tui);
  };

  mkBundle = import ./mk-bundle.nix {
    inherit lib dshBundleResolver kernelPatched;
    inherit (upstreamPkgs) stdenvNoCC nodejs-slim;
  };

  # 直接写在 nix 里的短 patch → mkBundle 要的文件形态。
  # `builtins.toFile` 在**求值期**写 store：纯函数、不产生 derivation、不是 IFD
  # （pkgs.writeText 也能用，但那是多一个构建步骤换同样的文件）。
  # label 只决定 store 里的文件名（排查时认得出是谁），不能带 `/` —— 带 scope 的
  # 包名（@jojo/...）要自己起一个无斜杠的 label。
  patchText = label: text: builtins.toFile "${label}.cordis.patch.yml" text;

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

  # ── 官方 ACP bundle（上游 nix 包集里没有，npm 上与 core 同步发布）──────────────
  #
  # 上游 flake 的 `dsh.bundles` 只覆盖它自己打包的那批（2026-10-15 实测 55 个里
  # 没有 acp）。官方把 ACP 作为「随 core 版本一起发布的独立 bundle」分发：
  # `@deepseek-ai/dsh-acp`（服务端插件）与 `@deepseek-ai/dsh-acp-app`（profile
  # bundle，插入 acp 行）。这里按 **kernel 版本**抓 npm tarball —— core 升级时对应
  # 版本要么同时存在（正常），要么抓取直接失败（上游漏发），不会出现「core 升了、
  # acp 还是旧版」的静默错配。
  dshVersion = upstreamPkgs.dsh.dsh-kernel.version;

  # npm tarball → 裸包目录（含 package.json），与 mkBundle 的 src 约定一致。
  npmSrc =
    { name, version, hash }:
    upstreamPkgs.runCommand "npm-${baseNameOf name}-${version}"
      {
        nativeBuildInputs = [
          upstreamPkgs.gnutar
          upstreamPkgs.gzip
        ];
        src = upstreamPkgs.fetchurl {
          url = "https://registry.npmjs.org/${name}/-/${baseNameOf name}-${version}.tgz";
          inherit hash;
        };
      }
      ''
        mkdir -p $out
        tar xzf "$src" -C $out --strip-components=1
      '';

  # dsh-acp 声明的是**精确** SDK 版本（"1.4.0"），所以这里在构建期断言：上游换
  # SDK 而我们仍钉旧版时必须立刻失败，而不是装一个它没要求的 SDK。
  acpSdkVersion = "1.4.0";
  acpSdkSrc = npmSrc {
    name = "@agentclientprotocol/sdk";
    version = acpSdkVersion;
    hash = "sha256-V76w93BbCUBuW8yYTR9qFBlAaAtMQnVb4Cb3f2Q2Wjc=";
  };
  dshAcpSrc = upstreamPkgs.runCommand "npm-dsh-acp-${dshVersion}" {
    nativeBuildInputs = [
      upstreamPkgs.gnutar
      upstreamPkgs.gzip
      upstreamPkgs.jq
    ];
    src = upstreamPkgs.fetchurl {
      url = "https://registry.npmjs.org/@deepseek-ai/dsh-acp/-/dsh-acp-${dshVersion}.tgz";
      hash = "sha256-+CC7VFRo7pPKrSj83eJSwFCyRay4NDSg4KLSYCZP9tY=";
    };
  } ''
    mkdir -p $out
    tar xzf "$src" -C $out --strip-components=1
    declared=$(jq -r '.dependencies["@agentclientprotocol/sdk"] // ""' "$out/package.json")
    [ "$declared" = "${acpSdkVersion}" ] || {
      printf 'dsh-local: dsh-acp ${dshVersion} requires @agentclientprotocol/sdk %s but nix pins ${acpSdkVersion}\n' "$declared" >&2
      exit 1
    }

    # ── 补丁：session/list 的摘要补上 updatedAt ────────────────────────────────
    #
    # 上游 `listSessions` 只投影 {sessionId, cwd}（TS 源码同形），连它手上已经有的
    # header.createdAt 都不发。客户端的选择器因此退化成「Untitled / unknown-time」：
    # agent-shell 的候选列是 directory/title/date/session-id，date 取
    # `(or updatedAt createdAt "unknown-time")`，于是同目录下的会话彼此无法区分，
    # 看起来像"只能手输 session id"。
    #
    # 为什么发的是 updatedAt 而不是 createdAt：ACP 的 SessionInfo **没有 createdAt
    # 字段**，只有 updatedAt（RFC 3339）—— 发 createdAt 会被 SDK 的 schema 丢掉。
    # header 里也只有 createdAt（epoch ms，见其排序与 cursor 编码都用数值相减），
    # 所以这里把它当"最后活动时间"发出：对 `session/list` 列出的非活跃会话，
    # 二者在语义上一致（活跃会话本来就被过滤掉）。
    #
    # title 补不了：JSONL header 里没有 title（实测该文件 0 次出现），标题只活在
    # 投影缓存，ACP 插件没有消费它 —— 那是上游的功能缺口，不是这一行能修的。
    #
    # 替换串按**语义**取最短前缀，不碰缩进：插入的字段写在对象字面量开头，原文件的
    # 多行字段原样留在后面。上游改写这一行时 --replace-fail 会立刻让构建失败。
    substituteInPlace "$out/lib/index.js" \
      --replace-fail \
      'sessions: page.map(({ sessionId, cwd }) => ({' \
      'sessions: page.map(({ sessionId, cwd, createdAt }) => ({ updatedAt: new Date(createdAt).toISOString(),'
  '';
  acpAppSrc = npmSrc {
    name = "@deepseek-ai/dsh-acp-app";
    version = dshVersion;
    hash = "sha256-jIA/Ru2+qFMzjFtPJ88GQ4/W8mjE2ZGvArWNLTwqPYY=";
  };

  # 给一个 bundle 的 node_modules 补上它自己 import 的**非 peer** 依赖。
  #
  # 为什么不直接改 mk-bundle.nix：mkBundle 的 installPhase 进 derivation 哈希 ——
  # 动一个字节（连注释的缩进都算：Nix 按最小缩进裁剪 `''` 字符串，一个第 0 列的行
  # 就会让整份脚本多出四个空格）就让**每个**本地 bundle 换哈希，级联重建
  # dsh-node-modules → dsh 包；而官方 bundle（base/headless/web-app）只是构建期
  # 输入、构完即被 GC，于是每次都要重拉（经代理常挂）或从源码编（约 40 分钟）。
  # 所以扩展做在包外：复制 mkBundle 的产物，只替换目标包的 node_modules。
  linkExtraNodeModules =
    {
      bundle,
      name,
      extras,
    }:
    let
      kernelNodeModules = "${kernelPatched}/lib/deepseek-harness/node_modules";
    in
    upstreamPkgs.runCommand (lib.strings.sanitizeDerivationName "${name}-with-deps") {
      nativeBuildInputs = [ upstreamPkgs.nodejs-slim ];
      # 组合校验读的是 passthru 与 nix-support 清单；两者都照 mkBundle 的约定带上。
      passthru = {
        dshBundle = true;
        dshBundleHelper = "buildDshBundle";
        runtimeDeps = bundle.passthru.runtimeDeps or [ ];
      };
      meta.description = "dsh bundle ${name} carrying its own non-peer dependencies";
    } ''
      mkdir -p "$out/lib/node_modules"
      cp -a ${bundle}/lib/node_modules/. "$out/lib/node_modules/"
      cp -a ${bundle}/nix-support "$out/nix-support"
      # store 里的目录是 555、文件是 444：`cp -a` 会把这些只读位带过来，接下来
      # 替换目标包的 node_modules 就会 "Permission denied"。mk-bundle.nix 在同一
      # 位置做同样的 chmod，这里照抄。
      chmod -R u+w "$out"

      dest="$out/lib/node_modules/${name}"
      [ -f "$dest/package.json" ] || {
        printf 'dsh-local: bundle output has no %s package.json\n' ${lib.escapeShellArg name} >&2
        exit 1
      }

      # 真目录而不是软链：Node 的查找顺序里 bundle 自己的 node_modules 是第一站。
      # 内核顶层条目逐个软链进来（scope 目录要展开合并，才能再往里加同一 scope 的包），
      # 额外包落在自己的 scope 下并覆盖同名内核副本（bundle 拥有它自己声明的那份）。
      rm -f "$dest/node_modules"
      mkdir -p "$dest/node_modules"
      for entry in ${kernelNodeModules}/*; do
        entryName=$(basename "$entry")
        case "$entryName" in
          @*)
            mkdir -p "$dest/node_modules/$entryName"
            for scoped in "$entry"/*; do
              ln -s "$scoped" "$dest/node_modules/$entryName/$(basename "$scoped")"
            done
            ;;
          *)
            ln -s "$entry" "$dest/node_modules/$entryName"
            ;;
        esac
      done
      ${lib.concatMapStringsSep "\n" (pkg: ''
        extraName=$(${lib.getExe upstreamPkgs.nodejs-slim} -p \
          "JSON.parse(require('node:fs').readFileSync('${pkg}/package.json','utf8')).name")
        case "$extraName" in
          @*/*)
            extraScope=''${extraName%%/*}
            mkdir -p "$dest/node_modules/$extraScope"
            ln -sfn ${pkg} "$dest/node_modules/$extraName"
            ;;
          *)
            ln -sfn ${pkg} "$dest/node_modules/$extraName"
            ;;
        esac
      '') extras}
    '';

  # acp bundle 对，分工照上游的包边界：
  #
  #   dsh-acp     —— 服务端插件本体。patch = []（顶层 acp 行由 acp-app 的 patch
  #                  插入，两边都插会撞成重复 id）。运行期只 import 一个外部包
  #                  （SDK），其余全是 kernel 里的 peer，所以走 linkExtraNodeModules。
  #                  acp-app 并不 import 它，只在 patch 里按名字引用它 —— 于是它
  #                  必须作为 bundle 出现在某个 profile 的清单里才会被装进安装树：
  #                  Loader 解析顶层行名时找的正是安装锚点。
  #   dsh-acp-app —— profile bundle：persona、禁 hmr、插入 acp-app-startup + acp 行。
  #                  自带 patch 逐字节落地（mkBundle 的约定）。
  acpBundles = [
    (linkExtraNodeModules {
      bundle = mkBundle {
        name = "@deepseek-ai/dsh-acp";
        version = dshVersion;
        src = dshAcpSrc;
        meta.description = "Automation-only ACP server plugin for dsh";
      };
      name = "@deepseek-ai/dsh-acp";
      extras = [ acpSdkSrc ];
    })
    (mkBundle {
      name = "@deepseek-ai/dsh-acp-app";
      version = dshVersion;
      src = acpAppSrc;
      patch = "${acpAppSrc}/cordis.patch.yml";
      meta.description = "Automation-only ACP stdio application profile bundle for dsh";
    })
  ];

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
  # （三个 shell-env 实现包、两个 tool 包、blackhole）。
  # 它们仍必须是 bundle —— 只有出现在 `dsh.profile.bundles` 里的包才会被 symlinkJoin
  # 进安装的 node_modules，进而才能被名字解析到 —— 但 patch 为空，不产生顶层行。
  # 这与官方 `dsh-tool-bash` 的处境完全相同：包在安装里，挂载与否由 preset 决定。
  # （autosync 不走这条路：它自己既声明三条路由行、也实现它们，见下。）

  # MCP 工具描述里的字面 {{...}} 组会让 dsh-system-prompt 的严格渲染器抛
  # "malformed prompt variable reference" 并失败整轮对话（上游 issue #711）。
  # 本插件挂 system-prompt/assemble waterfall，在 next() 之后把未注册的花括号组换成
  # 全角；已注册变量（model/cwd）保持插值。
  bracesSanitize = mkBundle {
    name = "dsh-braces-sanitize";
    src = pluginsDir + "/braces-sanitize";
    patch = patchText "dsh-braces-sanitize" ''
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
    patch = patchText "dsh-mcp" mcpEntries;
  };

  shellEnv = mkDeclBundle {
    name = "dsh-shell-env";
    description = "Credential injection through the trusted DSH_* shell-env registry (OpenBao / Woodpecker / HuggingFace).";
    patch = patchText "dsh-shell-env" ''
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

  # 三条模型同步路由（opencode-go / runinfra / deepseek-relay）合成一个 bundle：
  # 它们的实现共用一个骨架（modules/home/dsh/plugins/autosync/lib/plugin.js），
  # 只有路由默认值与合并策略不同，所以行里的 name 指向同包的子路径导出。
  # 拆成四个 bundle 时每次修复都要改三遍，副本还已经漂移（只有 runinfra/relay
  # 保留了既有条目的 compat）。
  autosync = mkBundle {
    name = "dsh-autosync";
    src = pluginsDir + "/autosync";
    meta.description = "Live model discovery for the opencode-go / opencode-free / runinfra / deepseek-relay routes.";
    patch = patchText "dsh-autosync" ''
      # relay / runinfra 的 /v1/models 是权威所以 reconcile（增删同步，保留仍在 live
      # 的既有条目的 compat / reasoningEfforts / 用户修正容量）；opencode-go 是
      # add-only + reportOnly —— 它的服务清单来自 pi-ai 静态 catalog，而一条 `models`
      # 会整体替换 catalog，物化只会把清单外的 id 丢掉、把没开通的 id 塞进来。
      # 它的 live 清单还按 opencode console 的逐模型开关过滤，与 catalog 两边都不等，
      # 所以只记日志（unresolved），不写设置。容量缺口的来源见 lib/catalog.js。
      # opencode-free 是同一个网关的 `-free` 子集，单独成路由：它没有 catalog，
      # models 列表就是唯一 owner，因此可以 reconcile（下架的免费档自动消失，
      # 新增的自动进来）。
      - insert:
          # baseURL 用官方文档（opencode.ai/v2/docs/console/go）的规范拼写
          # /inference/go/v1；旧拼写 /zen/go/v1 仍是活的别名，两者 2026-10-14
          # 实测返回同一份 40 条清单，别名哪天撤了不影响这里。
          - id: opencode-autosync
            name: dsh-autosync/opencode
            config:
              route: opencode-go
              baseURL: https://opencode.ai/inference/go/v1
              api: openai-completions
              apiKeyEnv: OPENCODE_API_KEY
              intervalMs: 43200000

          # 与上一条同网关同 key：只接管 `-free` 后缀，付费 id 仍归 catalog 路由。
          - id: opencode-free-autosync
            name: dsh-autosync/opencode-free
            config:
              route: opencode-free
              baseURL: https://opencode.ai/inference/go/v1
              api: openai-completions
              apiKeyEnv: OPENCODE_API_KEY
              intervalMs: 43200000
              includeSuffixes: ["-free"]

          - id: runinfra-autosync
            name: dsh-autosync/runinfra
            config:
              route: runinfra
              baseURL: https://api.runinfra.ai/v1
              api: openai-completions
              apiKeyEnv: RUNINFRA_GATEWAY_KEY
              intervalMs: 43200000

          # baseURL 走运行时 env：与 llm-pi-ai 的 deepseek-relay.baseURL 同一变量
          # （clan vars openai-relay/base-url，单一来源）。
          - id: deepseek-relay-autosync
            name: dsh-autosync/deepseek-relay
            config:
              route: deepseek-relay
              baseURL: !!js process.env.DEEPSEEK_RELAY_BASE_URL
              api: openai-completions
              apiKeyEnv: DEEPSEEK_RELAY_API_KEY
              intervalMs: 43200000
              # 只报告，不写 profile 层：这条路由的清单归 routes.nix，运行期写入会被
              # 下一次 rebuild 抹掉，留着写者只会让设置页与声明不一致。漂移由
              # `dsh-models-sync --check` 报出来（同一个 reconcile 实现）。
              reportOnly: true
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

  presets = mkBundle {
    name = "dsh-local-presets";
    # presetsPatch 本身就是产出 YAML 的 derivation：直接当构建输入，不再 readFile
    # （那是 IFD，会把 presets 的全部校验步骤拖进求值期）。
    patch = presetsPatch;
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
    patch = patchText "dsh-model-select-plus" ''
      # 只进 web profile：装进 TUI/headless 会因为解析不到客户端半区而崩溃
      # （2026-09-28 实测：dsh-tui 启动日志里的 "failed to import"）。
      - insert:
          - id: ui-model-select-plus
            name: '@local/dsh-model-select-plus'
            config: {}
    '';
    meta.description = "Searchable, provider-prefixed replacement for the composer model seat";
  };

  # 确定性压缩后端的说明符，被三处引用：my-minimal / my-router-standard 的 rewrites
  # 条目，以及 my-ptc 里把那行 shipped `compaction-basic` 换成它（presets.nix）。
  # 单点定义 —— 此前 presets.nix 走 `strenv(BLACKHOLE_COMPACTION)` 取一个从未定义
  # 的环境变量，yq 对未定义变量返回空串而不报错，产出的行是 `name: ""`，
  # 运行期报 `row 13 row 1 names no plugin`（2026-09-28 实测）。
  blackholeCompaction = "@jojo/dsh-blackhole/compaction";

  # preset 声明行里的相对说明符 → 绝对包名，按源文件分组（两份 router preset 用同名
  # 文件却要指向各自的包）。重写后若仍有残留则构建失败 —— 那条行会在运行期以
  # "failed to import" 静默失效。
  rewrites = {
    minimalExtras = {
      "./tool-processes.js" = "dsh-tool-processes";
      "./tool-ast-grep.js" = "dsh-tool-ast-grep";
      "./dsh-blackhole/lib/index.js" = "@jojo/dsh-blackhole";
      "./dsh-blackhole/lib/compaction.js" = blackholeCompaction;
    };
    ptcExtras = {
      "./tool-processes.js" = "dsh-tool-processes";
      "./tool-ast-grep.js" = "dsh-tool-ast-grep";
      "./dsh-blackhole/lib/index.js" = "@jojo/dsh-blackhole";
      "./dsh-blackhole/lib/compaction.js" = blackholeCompaction;
    };
    router = {
      "./router-bootstrap-v34.mjs?v=88" = "dsh-preset-router-standard/bootstrap";
      "./gitbash-executor.mjs?v=49" = "dsh-preset-router-standard/gitbash-executor";
    };
    myRouter = {
      "./router-bootstrap-v34.mjs?v=88" = "dsh-preset-my-router-standard/bootstrap";
      "./gitbash-executor.mjs?v=49" = "dsh-preset-my-router-standard/gitbash-executor";
      "./dsh-blackhole/lib/index.js" = "@jojo/dsh-blackhole";
      "./dsh-blackhole/lib/compaction.js" = blackholeCompaction;
      "./tool-ast-grep.js" = "dsh-tool-ast-grep";
    };
  };

  presetsPatch = import ./presets.nix {
    inherit lib rewrites blackholeCompaction;
    inherit (upstreamPkgs) pkgs;
    webAppPresetsDir = "${upstreamBundles.web-app}/lib/node_modules/@deepseek-ai/dsh-web-app/presets";
  };

  # ── profile 播种器（替换上游的 dsh-sync-profiles）─────────────────────────
  #
  # ## 为什么不用上游的 managed / mutable 二选一
  #
  # 上游把 `package.json` / `cordis.patch.yml` / `pnpm-workspace.yaml` 捆成一个
  # managedFiles 指纹集，于是只剩两个都错的选项（两个失败模式都在本机实测过）：
  #
  #   mode = "managed"（默认）—— 每次 dsh 启动都按指纹把三个文件从模板还原。
  #     `cordis.patch.yml` 正是 dsh 运行时的写盘目标（Settings 表单、config-editor、
  #     dsh-tap 的 llm-pi-ai 启停都写它），于是**每一次启动都抹掉上一次的运行时设置**。
  #     实测：往 profile patch 追加一行后跑 `dsh --help`，stderr 出现
  #     "dsh: updating managed profile: nix-web"，追加的行消失。受影响的是模型选择、
  #     欢迎页版本、TUI 的 /settings（全屏、图片、思考强度）、dsh-tap 的模型启停 ——
  #     全是「设了下次就没了」。
  #   mode = "mutable" —— 只在目录不存在时播种一次，之后 package.json 也不再更新。
  #     于是往 hostBundles 里加一个 bundle 不会生效，且没有任何提示（静默退化）。
  #
  # 根源是这三个文件的所有权本来就不一样，上游把它们当一个整体才逼出这个二选一：
  #
  #   package.json / pnpm-workspace.yaml   nix 拥有（bundle 清单、pnpm 布局）
  #   cordis.patch.yml                     dsh 拥有（运行时设置的全部写入都在这里）
  #
  # 本播种器按所有权拆开，两个失败模式同时消失：
  #
  #   目录不存在  → 整份模板播种（cordis.patch.yml 得到 `[]` 起点）
  #   目录已存在  → 只同步 nix 拥有的那两个文件，cordis.patch.yml 一个字节都不碰
  #
  # 走的是上游 `profileSeeder` 参数（package.nix 注释里的 "Optional external
  # profile artifact seeder used by split integrations"）—— 它同时被用作 wrapper 的
  # runtimeInput，所以脚本名必须叫 dsh-sync-profiles、接受一个可选的 profile 名参数。
  mkProfileSeeder =
    { profiles, artifacts }:
    let
      # 物化名 = 上游的 nix- 前缀；模板目录名就是它。
      targets = map (name: "nix-${name}") (builtins.attrNames profiles);
      # sync_profile 的实参：<profile 名> <模板目录> <目标目录>。
      syncArgs =
        target:
        "${lib.escapeShellArg target} ${lib.escapeShellArg "${artifacts.profileTemplates}/${target}"} \"$home/profiles/${target}\"";
      syncBody = target: "  sync_profile ${syncArgs target}";
      syncArm = target: "  ${target}) sync_profile ${syncArgs target} ;;";
    in
    upstreamPkgs.writeShellApplication {
      name = "dsh-sync-profiles";
      runtimeInputs = with upstreamPkgs; [
        coreutils
        diffutils
        gnugrep
        util-linux
      ];
      inheritPath = false;
      text = ''
        home=''${DSH_HOME:-''${HOME:+$HOME/.dsh}}
        [ -n "$home" ] || exit 0

        mkdir -p "$home/profiles"
        exec 9>"$home/profiles/.nix-sync.lock"
        flock 9

        die() {
          printf 'dsh: %s\n' "$1" >&2
          exit 1
        }

        # nix 拥有：bundle 清单与 pnpm 布局。dsh 只读。
        nixOwned="package.json pnpm-workspace.yaml"

        copy_owned_file() {
          local source=$1 destination=$2 temporary

          [ -f "$source" ] || die "managed source is missing: $source"
          [ ! -L "$destination" ] || die "refusing to overwrite symlink: $destination"
          if [ -e "$destination" ] && [ ! -f "$destination" ]; then
            die "refusing to overwrite non-file: $destination"
          fi
          if [ -f "$destination" ] && cmp -s "$source" "$destination"; then
            return 0
          fi

          temporary=$(mktemp "$destination.tmp.XXXXXX")
          cp --dereference --no-preserve=mode "$source" "$temporary"
          mv -f "$temporary" "$destination"
        }

        validate_managed_dir() {
          local profile=$1 destination=$2

          [ ! -L "$destination" ] || die "refusing to follow profile symlink: $destination"
          [ -d "$destination" ] || die "profile path is not a directory: $destination"
          [ -f "$destination/.nix-managed" ] \
            || die "refusing to take over existing unmanaged profile '$profile' at $destination"
          grep -Fxq 'owner=nix' "$destination/.nix-managed" \
            || die "managed marker has an unexpected owner: $destination/.nix-managed"
          grep -Fxq "profile=$profile" "$destination/.nix-managed" \
            || die "managed marker belongs to another profile: $destination/.nix-managed"
        }

        install_profile_dir() {
          local parent=$1 source=$2 destination=$3 destination_mode temporary

          parent=$(dirname -- "$destination")
          destination_mode=$(stat --format='%a' -- "$parent") \
            || die "failed to inspect profile parent: $parent"

          temporary=$(mktemp -d "$parent/.''${destination##*/}.tmp.XXXXXX") \
            || die "failed to stage managed profile: $destination"
          if ! cp -r --dereference --no-preserve=mode "$source"/. "$temporary"/; then
            rm -rf --one-file-system -- "$temporary"
            die "failed to stage managed profile: $source"
          fi
          # 记的是只有 owner/schema/profile 的标记：留指纹就得在每次同步后重算，
          # 而本播种器只用 cmp 判等，一个会说谎的指纹不如不写。
          printf 'owner=nix\nschema=1\nprofile=%s\n' "''${destination##*/}" \
            > "$temporary/.nix-managed"
          chmod "$destination_mode" "$temporary" || {
            rm -rf --one-file-system -- "$temporary"
            die "failed to set managed profile mode: $destination"
          }

          if [ -e "$destination" ] || [ -L "$destination" ]; then
            rm -rf --one-file-system -- "$temporary"
            die "profile appeared during sync: $destination"
          fi
          if ! mv --no-copy --update=none-fail -T -- "$temporary" "$destination"; then
            rm -rf --one-file-system -- "$temporary"
            die "failed to install managed profile: $destination"
          fi
        }

        sync_profile() {
          local profile=$1 source=$2 destination=$3 file

          [ -d "$source" ] || die "managed profile source is missing: $source"

          if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
            install_profile_dir "$(dirname -- "$destination")" "$source" "$destination"
            return 0
          fi

          validate_managed_dir "$profile" "$destination"

          # cordis.patch.yml 故意不在此列表：它是 dsh 的写入目标，nix 不碰。
          for file in $nixOwned; do
            copy_owned_file "$source/$file" "$destination/$file"
          done
        }

        case "''${1:-}" in
        "")
        ${lib.concatMapStrings (t: "${syncBody t}\n") targets}  ;;
        ${lib.concatMapStrings (t: "${syncArm t}\n") targets}  *)
            ;;
        esac
      '';
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
    let
      args = {
        bundles = upstreamBundles;
        dsh-kernel = kernelPatched;
        inherit profiles defaultProfile homePatch;
        # 传了 profileSeeder 后 wrapper 就改看 profileDefaultProfile（见上游
        # package.nix 的 launcherDefaultProfile 三元式）；不传它，argv 里没有
        # --profile 时就不再注入默认 profile，CLI 会落到上游内置的 web。
        profileDefaultProfile = defaultProfile;
      };

      # profile 模板里 `requiresWeb/Tui` 追加的官方 bundle 取自**装配包自己的**
      # `bundles`（profiles.nix 的 webBundle/tuiBundle）。过去这里从
      # `upstreamPkgs.dsh.dsh` 取，拿到的是未重绑定的那份：模板清单指向未打补丁
      # 的官方 tui bundle，与安装树不同源，还额外触发一次 dsh-tui 源码构建。
      # seeder 本身是装配包的入参，回指装配包会递归，所以先装一份不带 seeder 的，
      # 只取它的 mkProfileArtifacts（纯模板计算，不构建整包）。
      artifactSource = upstreamPkgs.dsh.dsh.override args;
      artifacts = artifactSource.passthru.mkProfileArtifacts { inherit profiles; };
    in
    upstreamPkgs.dsh.dsh.override (
      args // { profileSeeder = mkProfileSeeder { inherit profiles artifacts; }; }
    );

  # ── 宿主包 shim：让 dsh-tui 自己的入口能"托管"这次启动 ──────────────────────
  #
  # dsh-tui 上游的默认启动线是它**自己的入口**（lib/types/dsh-adapter/host-entry.js）：
  # 先把可交互界面挂到终端，再在同一进程组合 profile —— 插件树、MCP 握手、模型目录
  # 同步全部落在首帧之后。`dsh --profile` 那条线要等整棵树装完才出画面（本机实测首帧：
  # 入口 0.9~1.6s，`dsh --profile` 5.7~6.6s）。
  #
  # 入口用 host-dsh.js 的 findHostDsh 定位宿主：顺着 PATH 上第一个 `dsh` 的 realpath
  # 往上找，必须找到一个 package.json 里 `name === "@deepseek-ai/dsh"` 的包目录，再从
  # 那里以 file-URL 加载 8 个宿主模块（cordis / dsh-app-boot / cordis-plugin-loader /
  # dsh-home-paths / dsh-launch-environment / dsh-cmdline / @deepseek-ai/dsh/profile-boot /
  # dsh-http-proxy）。nix 的 dsh 是 wrapper 脚本 + 扁平 bin/lib 布局，没有这个包目录 →
  # 入口打印 "the installed dsh cannot host this launch" 并回退 `dsh --profile`。
  #
  # 这里补一个最小的"看起来像 npm 装的 @deepseek-ai/dsh"的目录：
  #   package.json   装配包的 manifest —— profile-boot 的 INSTALL_ANCHOR 就是
  #                  <pkg>/package.json，profile bundle 从它旁边解析
  #   lib/           → 装配包的 lib：**必须落到真路径**，ESM 的 import.meta.url 决定
  #                  INSTALL_ANCHOR；指到 kernelPatched 那层会解析不到任何 bundle
  #                  （实测：18 个 bundle 全部 "cannot resolve profile bundle"）
  #   node_modules/  → 装配包的 node_modules（symlinkJoin 后的全量 bundle 在这里）
  #   dsh            必须是 $out 里的真文件：findHostDsh 对候选取 realpath，若是指向
  #                  store 脚本的 symlink，realpath 又会走出本目录 → 找不到包目录
  #
  # 所以它必须由**装配后的** dsh 生成，因此做成函数、由调用方传入。
  mkDshHostPackage =
    dsh:
    upstreamPkgs.runCommand "dsh-host-package"
      {
        pname = "dsh-host-package";
        version = upstreamPkgs.dsh.dsh-kernel.version;
        meta.description = "Host package shim that lets dsh-tui's own entry host the launch";
      }
      ''
        mkdir -p $out
        cp ${dsh}/lib/deepseek-harness/package.json $out/package.json
        ln -s ${dsh}/lib/deepseek-harness/lib $out/lib
        ln -s ${dsh}/lib/deepseek-harness/node_modules $out/node_modules
        cat > $out/dsh <<SHELL
        #!${upstreamPkgs.runtimeShell}
        exec ${dsh}/bin/dsh "$@"
        SHELL
        chmod +x $out/dsh
      '';

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
    patchText
    mkDsh
    mkDshHostPackage
    acpBundles
    # CLI 消费者要拿它的 lib/cli.js：这条依赖不走 hostBundles 的装配，直接引用包路径。
    autosync
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
