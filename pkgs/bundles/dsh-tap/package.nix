# dsh-tap bundle —— 从 taikaikaikai-pixel/dsh-tap 源码构建。
#
# 为什么必须走 bundle 层（2026-09-29）：
# dsh-tap 的运行时把 `llm-pi-ai` **整行**当成自己的数据库——设置卡里同步
# CodeBuddy 目录、逐模型启停/改上限、把 Trae CN / Qoder CN / 额外 key 型
# 服务商注册进模型选择器，全部经宿主 settings seam 写进 profile 的
# cordis.patch.yml。而 dsh 的 patch 层顺序是
#
#   bundle 层（各包自带 cordis.patch.yml）
#     → profile 层（$DSH_HOME/profiles/<p>/cordis.patch.yml）
#     → home 层（$DSH_HOME/cordis.patch.yml，即本仓库的 providerPatch）
#     → 命令行 overlay
#
# （packages/boot/app-boot/src/profile-context.ts 的 readProfilePatches），
# 且 config 是**整块替换**而不是逐键深合并
# （cordis-plugin-include/lib/index.js: `target[key] = value`）。
#
# 于是只要 home 层还留着一行 llm-pi-ai，两件事同时发生：
#   1. dsh-tap 自带的 codebuddy 路由被 home 层覆盖掉，主聊天没有路由；
#   2. 它此后每一次写入都被 config-editor 拒绝——
#      "Configuration for \"llm-pi-ai\" is overridden by a home patch or
#      command-line overlay"（packages/boot/config-editor/src/index.ts，
#      inherited 只由 bundle 层 + profile 层去掉本行 config 合成，不含 home 层）。
#
# 出路只有一条：本仓库的路由表迁到 bundle 层，并与 dsh-tap 自带的那一行
# 合成**同一行**——这样 inherited 里就同时有我们的 7 条和它的 codebuddy，
# 设置卡的 next = inherited + 改动，写回 profile 层后 effective == next，守卫通过。
#
# 合并只能在构建期做（见 postInstall）：读 dsh-tap 原文的 cordis.patch.yml，
# 把 modules/home/dsh 渲染的 providers 映射并进它的 llm-pi-ai.config。只用
# yq 的 `*=` 深合并一层，其余行（insert / agent-default-model / web）与原文
# 注释、!!js 标量都原样保留。
#
# 运行时依赖：package.json 声明了 @deepseek-ai/schemastery 与 yaml，但按 dsh
# 的规矩**内核拥有所有 peer**——linkKernelNodeModules 会先把 bundle 里同名包
# 删掉，再从 dsh-kernel 链进来，所以实际版本以内核为准（内核是 3.18.4，
# 声明是 3.18.1）。npm 安装本身不是白做：它按 package.json 的 `files` 清单
# 决定发布面，上游加文件时自动跟随，不会像手写 cp 列表那样静默漏掉。
#
# client 半区（lib/client.js）要 react，但 react 不在内核 node_modules 里——
# 它由 web 客户端模块加载器的 seed module 提供（client.js 里是
# `window.__ModuleLoader__.load({ factory: (require) => ... })` 的 require("react")），
# 所以不需要、也不应该往 bundle 里塞 react。headless / dsh-tui profile 没有
# web 客户端加载器，这个半区就是惰性的（上游 agent-team-profile 的 README
# 明确：UI 插件 host 入口不动，只有 Web Client loader 挂载浏览器入口）。
{
  lib,
  fetchFromGitHub,
  fetchNpmDeps,
  buildDshBundle,
  dsh-kernel,
  yq-go,
  nix-update-script,
  # 本仓库 llm-pi-ai 的 providers 映射（YAML 文本，含 !!js 标量），由
  # modules/home/dsh/default.nix 渲染。单一事实来源仍是
  # modules/home/llm-routes/routes.nix，这里只做传输。
  dshTapProviders,
}:

buildDshBundle (finalAttrs: {
  pname = "dsh-tap";
  version = "0.13.0";

  src = fetchFromGitHub {
    owner = "taikaikaikai-pixel";
    repo = "dsh-tap";
    rev = "refs/tags/v${finalAttrs.version}";
    hash = "sha256-FfSqJM5qGVb2cnEEJy6D7JAGfnYiY2YjnbT7hTRoojI=";
  };

  npmDeps = fetchNpmDeps {
    inherit (finalAttrs) src;
    hash = "sha256-PM36MjlKUJJqzMxtVFIq02hsHGpgxxxv9zHjckuySbA=";
  };

  # 纯 ESM、无构建步骤：package.json 只有 verify:* 脚本，没有 build。
  # 不关掉的话 npmBuildHook 会以 "Missing script: build" 失败。
  dontNpmBuild = true;

  nativeBuildInputs = [ yq-go ];

  linkKernelNodeModules = dsh-kernel;

  # 上游用 yaml 包的**默认 schema** 解析自己的 cordis.patch.yml（index.js 的
  # readStaticModels 与 patchEntryIds 各一次）。那个文件在本仓库合并进 providers
  # 之后含两个 `!!js` 标量（deepseek-relay / openai 的 baseURL 走
  # process.env.DEEPSEEK_RELAY_BASE_URL），而默认 schema 不认识
  # tag:yaml.org,2002:js —— 每次进程启动刷 4 行
  #   YAMLWarning: Unresolved tag: tag:yaml.org,2002:js at line 397, column 18
  #
  # 功能上无害（两处只读 `r.id` 与 `providers.codebuddy.models`，未解析的标量
  # 退化成字面字符串，碰不到），但每次启动污染 stderr。dsh 自己的读取面全部
  # 注册了该 tag —— app-boot 的 entryListSchema 是 js-yaml JSON_SCHEMA.extend(JsExpr)，
  # config-editor 的 parseDocument 也带 customTags 并把 `{__jsExpr}` 回写成
  # `!!js`（写入 profile 层因此能原样保真）。所以这是上游读取侧的单一缺陷。
  #
  # 这里注册同一个 tag（值原样保留），只影响读取，不改写任何文件。
  # --replace-fail：上游改了这两处写法就让构建失败，不会静默退回满屏警告。
  postPatch = ''
    substituteInPlace index.js \
      --replace-fail "import YAML from 'yaml'" \
"import YAML from 'yaml'

// LOCAL PATCH (nix-config)：cordis.patch.yml 允许 !!js 标量，默认 schema 不认识
// 该 tag。注册后解析静默，值语义与 dsh 的 entryListSchema 一致。
const PATCH_YAML_TAGS = [{ tag: 'tag:yaml.org,2002:js', resolve: (value) => value }]
const parsePatchYaml = (text) => YAML.parse(text, { customTags: PATCH_YAML_TAGS })"

    substituteInPlace index.js \
      --replace-fail "YAML.parse(readFileSync(PATCH_FILE, 'utf8'))" \
        "parsePatchYaml(readFileSync(PATCH_FILE, 'utf8'))"
  '';

  # 本段由 buildDshBundle 排在 linkKernelNodeModulesScript 之前执行，所以
  # 合并用的是 bundle 里那份**原文** cordis.patch.yml。
  postInstall = ''
    patch="$out/lib/node_modules/dsh-tap/cordis.patch.yml"
    [ -f "$patch" ] || {
      printf 'dsh-tap bundle: package.json 的 files 清单没带上 cordis.patch.yml\n' >&2
      exit 1
    }

    # 先确认上游形状还是"一行 llm-pi-ai + 非空 providers 映射"。yq -e 在
    # 条件为假时退出码非 0 —— 上游一改结构就在这里失败，不会静默合并不上
    # 导致本仓库 7 条路由凭空消失。
    yq -e '(.[] | select(.id == "llm-pi-ai") | .config.providers) | keys | length > 0' "$patch" >/dev/null

    ours="$TMPDIR/dsh-tap-ours.yml"
    cp ${dshTapProviders} "$ours"

    # `*=` 在 yq 里是深合并（右侧优先）；作用在 .config 上，所以 providers
    # 的两侧键并集就是结果。两侧 provider id 不重叠（我们 7 条 vs 它的
    # codebuddy），不存在覆盖语义的歧义。
    merged="$TMPDIR/dsh-tap-merged.yml"
    SHIPPED="$patch" OURS="$ours" yq -n '
      load(strenv(OURS)) as $o |
      load(strenv(SHIPPED)) | (.[] | select(.id == "llm-pi-ai") | .config) *= $o
    ' > "$merged"

    # 逐条核对我们的 provider id 真的落进去了。缺任何一条 = 该上游路由在
    # 模型选择器里消失，属于静默退化，宁可构建失败。
    while IFS= read -r id; do
      ID="$id" yq -e \
        '(.[] | select(.id == "llm-pi-ai") | .config.providers) | has(strenv(ID))' \
        "$merged" >/dev/null || {
        printf 'dsh-tap bundle: 合并后丢失 provider %s\n' "$id" >&2
        exit 1
      }
    done < <(yq -r '.providers | keys | .[]' "$ours")

    install -m644 "$merged" "$patch"
  '';

  passthru = {
    inherit (finalAttrs) npmDeps;

    updateScript = nix-update-script {
      extraArgs = [
        "--flake"
        "--override-filename=pkgs/bundles/dsh-tap/package.nix"
      ];
    };
  };

  meta = {
    description = "Unofficial upstream plugin bundle for dsh: CodeBuddy / TraeWork CN / Qoder CN plus a key-type OpenAI-compatible provider registry";
    descriptions.zh-CN = "dsh 的非官方上游插件包：CodeBuddy / TraeWork CN / Qoder CN 与 key 型 OpenAI 兼容服务商注册表";
    homepage = "https://github.com/taikaikaikai-pixel/dsh-tap";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
})
