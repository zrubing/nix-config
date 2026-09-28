# dsh-tap bundle 的本地打包。
#
# ## 为什么它不是普通的 npm bundle
#
# dsh-tap 的运行时把 `llm-pi-ai` **整行**当成自己的数据库：设置卡里同步 CodeBuddy
# 目录、逐模型启停与改上限、把 Trae CN / Qoder CN / 额外 key 型服务商注册进模型
# 选择器，全部经宿主 settings seam 写进 profile 的 cordis.patch.yml。
#
# 而 dsh 的 patch 层顺序是
#
#     bundle 层（各包自带 cordis.patch.yml）
#       → profile 层（$DSH_HOME/profiles/<p>/cordis.patch.yml）
#       → home 层（$DSH_HOME/cordis.patch.yml）
#       → 命令行 overlay
#
# 且 config 是**整块替换**而不是逐键深合并（cordis-plugin-include 的
# `target[key] = value`）。于是只要 home 层或 profile 层还留着一行 llm-pi-ai：
#
#   1. dsh-tap 自带的 codebuddy 路由被覆盖掉，主聊天没有路由；
#   2. 它此后每一次写入都被 config-editor 拒绝 ——
#      "Configuration for \"llm-pi-ai\" is overridden by a home patch or
#      command-line overlay"（config-editor 的 inherited 只由 bundle 层 + profile
#      层去掉本行 config 合成，不含 home 层）。
#
# 出路只有一条：本仓库的路由表迁到 bundle 层，并与 dsh-tap 自带的那一行合成**同一行**
# —— 这样 inherited 里同时有我们的 7 条和它的 codebuddy，设置卡的 next = inherited
# + 改动，写回 profile 层后 effective == next，守卫通过，双方都不丢。
#
# ## 合并为什么在构建期做
#
# 读 dsh-tap 原文的 cordis.patch.yml，把 modules/home/llm-routes 渲染的 providers
# 映射并进它的 llm-pi-ai.config。只用 yq 的 `*=` 深合并一层，其余行（insert /
# agent-default-model / web）与原文注释、!!js 标量全部原样保留。
#
# 两侧 provider id 不重叠（本仓库 7 条 vs 它的 codebuddy），所以不存在覆盖语义的歧义。
# 合并后逐条核对本仓库的 provider id 真的落进去了：缺任何一条 = 该上游路由在模型
# 选择器里消失，属静默退化，宁可构建失败。
{
  lib,
  pkgs,
  buildDshBundle,
  kernelPatched,
  llmPiAiProviders,
}:

buildDshBundle (finalAttrs: {
  pname = "dsh-tap";
  version = "0.13.0";

  src = pkgs.fetchFromGitHub {
    owner = "taikaikaikai-pixel";
    repo = "dsh-tap";
    rev = "refs/tags/v${finalAttrs.version}";
    hash = "sha256-FfSqJM5qGVb2cnEEJy6D7JAGfnYiY2YjnbT7hTRoojI=";
  };

  npmDeps = pkgs.fetchNpmDeps {
    inherit (finalAttrs) src;
    hash = "sha256-PM36MjlKUJJqzMxtVFIq02hsHGpgxxxv9zHjckuySbA=";
  };

  # 纯 ESM、无构建步骤：package.json 只有 verify:* 脚本，没有 build。
  # 不关掉的话 npmBuildHook 会以 "Missing script: build" 失败。
  dontNpmBuild = true;

  nativeBuildInputs = [ pkgs.yq-go ];

  linkKernelNodeModules = kernelPatched;

  # 上游用 yaml 包的**默认 schema** 解析自己的 cordis.patch.yml（index.js 的
  # readStaticModels 与 patchEntryIds 各一次）。那个文件在本仓库合并进 providers
  # 之后含两个 `!!js` 标量（deepseek-relay / openai 的 baseURL 走
  # process.env.DEEPSEEK_RELAY_BASE_URL），而默认 schema 不认识
  # tag:yaml.org,2002:js —— 每次进程启动刷 4 行
  #   YAMLWarning: Unresolved tag: tag:yaml.org,2002:js
  #
  # 功能上无害（两处只读 `r.id` 与 `providers.codebuddy.models`，未解析的标量退化成
  # 字面字符串，碰不到），但每次启动污染 stderr。dsh 自己的读取面全部注册了该 tag ——
  # app-boot 的 entryListSchema 是 js-yaml JSON_SCHEMA.extend(JsExpr)，config-editor
  # 的 parseDocument 也带 customTags 并把 `{__jsExpr}` 回写成 `!!js`（写入 profile 层
  # 因此能原样保真）。所以这是上游读取侧的单一缺陷。
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

  # 本段由 buildDshBundle 排在 linkKernelNodeModulesScript 之前执行，所以合并用的是
  # bundle 里那份**原文** cordis.patch.yml。
  postInstall = ''
    patch="$out/lib/node_modules/dsh-tap/cordis.patch.yml"
    [ -f "$patch" ] || {
      printf 'dsh-tap bundle: package.json 的 files 清单没带上 cordis.patch.yml\n' >&2
      exit 1
    }

    # 先确认上游形状还是「一行 llm-pi-ai + 非空 providers 映射」。yq -e 在条件为假时
    # 退出码非 0 —— 上游一改结构就在这里失败，不会静默合并不上导致 7 条路由消失。
    yq -e '(.[] | select(.id == "llm-pi-ai") | .config.providers) | keys | length > 0' "$patch" >/dev/null

    ours="$TMPDIR/dsh-tap-ours.yml"
    cp ${llmPiAiProviders} "$ours"

    # `*=` 在 yq 里是深合并（右侧优先）；作用在 .config 上，所以 providers 的两侧键
    # 并集就是结果。
    merged="$TMPDIR/dsh-tap-merged.yml"
    SHIPPED="$patch" OURS="$ours" yq -n '
      load(strenv(OURS)) as $o |
      load(strenv(SHIPPED)) | (.[] | select(.id == "llm-pi-ai") | .config) *= $o
    ' > "$merged"

    # 逐条核对本仓库的 provider id 真的落进去了。
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

    updateScript = pkgs.nix-update-script {
      extraArgs = [
        "--flake"
        "--override-filename=pkgs/dsh-local/dsh-tap.nix"
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
