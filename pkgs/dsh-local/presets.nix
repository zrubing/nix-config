# 本地 agent preset 的声明行生成。
#
# ## 背景：0.1.7 起 preset 是声明行，不是目录
#
# 上游删除了 `$DSH_HOME/.agent-presets` 目录机制，preset 变成一条普通 cordis 行：
#
#     - insert:
#         - id: preset-<id>
#           name: '@deepseek-ai/dsh-agent-preset'
#           config: { id, name, description, order, plugins: [<普通 cordis 行>] }
#
# `plugins` 里就是普通插件行，`name` 可以是绝对包名或相对说明符。
#
# ## 为什么这里用绝对包名
#
# 旧方案把 preset 的资源放 `~/.dsh/profiles/<p>/nix-presets/`，行里写
# `./nix-presets/dsh-blackhole/lib/index.js`，于是需要：资源目录软链、目录级
# node_modules shim、以及「相对说明符统一加前缀」的重写规则 —— 三者都只是为了让
# 相对路径解析得到。
#
# 改成绝对包名后这些全部消失：本地工具被装成 npm 包（dsh-tool-processes /
# dsh-tool-ast-grep / @jojo/dsh-blackhole），preset 行直接写包名，由 dsh 的两锚点
# 解析（dsh 安装目录优先，profile 目录其次）找到 —— 与官方 preset 引用
# `@deepseek-ai/dsh-tool-bash` 完全同构。
#
# ## 两条 delta preset，两条整份 preset
#
#   my-minimal / my-ptc = shipped minimal / ptc 的行 + 本地增量
#     shipped 部分在**构建期**从 web-app bundle 的 presets/*.patch.yml 读取，所以
#     上游更新自动跟随；本地增量来自各自的 extras.cordis.yml。
#
#   router-standard / my-router-standard = 整份 agent.cordis.yml
#     它们不基于 shipped preset，是自成一体的路由套件。
#
# ## 失败要大声
#
# 上游改结构（shipped preset 不再恰好一条声明、ptc 的 compaction 行不再恰好一条
# 且只有 id/name 两个键）会让本 derivation 直接失败，不会静默产出漂移的 preset。
# 重写后若仍残留 `./` 说明符也失败 —— 那说明包名表漏了一项，该行会在运行期以
# "failed to import" 静默失效。
{
  lib,
  pkgs,
  # web-app bundle 的 presets/ 目录：shipped preset 声明的来源。
  webAppPresetsDir,
  # 每份源文件的重写表：{ <label> = { "<相对说明符>" = "<包名>"; }; }
  #
  # 为什么按文件分组而不是一张全局表：preset 的 `config.plugins[].name` 不受
  # app-boot 的 anchorInsertedPluginNames 处理（那个函数只走 insert 顶层与 group 的
  # config，不进 config.plugins），所以相对说明符保持原样、由运行期按 **profile 目录**
  # 解析。旧方案因此必须在每个 profile 里投一份 nix-presets 资源目录。
  #
  # 两份 router preset 用的是同名文件（router-bootstrap-v34.mjs / gitbash-executor.mjs），
  # 却要指向各自的包，所以映射必须按文件给。
  rewrites,
  # 确定性压缩后端的说明符。my-ptc 要用它替换 shipped `compaction-basic` 那一行 ——
  # 那条替换发生在下面的 yq -n 生成阶段，所以这个值必须作为字面量注入表达式，
  # 不能用 `strenv()` 读环境变量（未定义时 yq 静默给空串，产出的行 `name: ""` 直到
  # 运行期才以 `names no plugin` 暴露）。
  blackholeCompaction,
}:

let
  presetsDir = ../../modules/home/dsh/agent-presets;
  webAppPresets = webAppPresetsDir;

  # 把 patch 文件里的相对说明符重写成绝对包名。
  # 键是**字面写法**（如 `./tool-processes.js`，可能带 `?v=` 查询串），值是包名；
  # yq 的 sub() 用正则，所以键按正则转义后再锚定整串，避免 `./a.js` 误伤 `./a.js.map`。
  rewriteExpr = map: lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      from: to: ''| sub(${builtins.toJSON "^${lib.escapeRegex from}$"}; ${builtins.toJSON to})''
    ) map
  );

  # 把每个 map 的 `name` 键里的相对说明符重写成绝对包名。
  #
  # ## 为什么必须显式 `select(has("name"))`（实测，yq 4.53.3）
  #
  # yq 的 `|=` 是**路径赋值**，不是「先取值再写回」：路径 `.. | ... | .name` 里的
  # `.name` 是路径的最后一段，对没有该键的 map 求值时会**创建**它（值为 null）。
  # 后面挂的 `select(tag == "!!str")` 只过滤结果，拦不住键已经被建出来：
  #
  #     yq -n '{"a": {"b": 1}} | (.a.c | select(tag == "!!str")) |= "x"'
  #     → a: {b: 1, c: null}
  #
  # 所以 `..` 扫过的每一个没有 name 的 map 都会被补上一个 `name: null`。实测同一份
  # my-minimal/extras.cordis.yml：无守卫 5 处 `name: null`，加守卫 0 处，而重写结果
  # 两者相同 —— 守卫不改变功能，只堵住这个副作用。
  #
  # 落到 preset 上是灾难：`config`、`isolate` 这些子 map 全都被插进 `name: null`，
  # 而插件 Config 是严格 schema，"unknown key name" 让 preset 直接挂载失败。
  # 2026-09-28 实测：4 份自定义 preset 在 Web 设置页全部显示 "Failed to load"，
  # 报错含 `plan-mode: unknown key(s) name` / `tool-result-pruner: unknown key "name"`。
  #
  # 这是静默损坏 —— 构建期不报错，`--dump-config` 也只是多几行 `name: null`。所以
  # 除了守卫，下面还有一道后置断言（见 `checkNoStrayName`）。
  rewrite = label: name: src: ''
    cp ${src} "$TMPDIR/${name}"
    chmod u+w "$TMPDIR/${name}"
    yq -i '
      (.. | select(tag == "!!map") | select(has("name")) | .name | select(tag == "!!str")) |=
        (. ${rewriteExpr rewrites.${label}})
    ' "$TMPDIR/${name}"
  '';

  # 后置断言：文件里每个 `name` 键都必须是非空字符串。
  #
  # 两类静默损坏都落在这里，两者都是「build 通过、--dump-config 通过、运行期挂载
  # 失败」，只能靠断言在构建期抓：
  #   - yq `|=` 路径赋值补出的 `name: null`（见 rewrite 上方说明）→ 插件严格 schema
  #     报 "unknown key name"；
  #   - 生成阶段插入的空 name（曾因 `strenv()` 取到未定义变量而产出 `name: ""`）
  #     → loader 报 "names no plugin"。
  #
  # 对四个重写产物各跑一次，对最终 $out 再跑一次 —— 后者防的是本文件后续改动（比如
  # 再对载入的文档做 `|=`）重新把同一类漂移带回来。
  checkNoStrayName = file: ''
    stray=$(yq -r '
      [.. | select(tag == "!!map") | select(has("name"))
         | select((.name | type) != "!!str" or .name == "")] | length
    ' "${file}")
    [ "$stray" -eq 0 ] || {
      printf 'dsh-local presets: %s has %s non-string or empty "name" key(s)\n' "${file}" "$stray" >&2
      printf 'dsh-local presets: inspect with: yq '"'"'.. | select(tag == "!!map") | select(has("name")) | select((.name | type) != "!!str" or .name == "")'"'"' %s\n' "${file}" >&2
      exit 1
    }

    rows=$(yq -r '
      [.. | select(tag == "!!seq") | .[] | select(tag == "!!map") | select(has("id"))
         | select((has("name") | not) or (.name | type) != "!!str" or .name == "")] | length
    ' "${file}")
    [ "$rows" -eq 0 ] || {
      printf 'dsh-local presets: %s has %s plugin row(s) whose id carries no usable name\n' "${file}" "$rows" >&2
      exit 1
    }
  '';
in
pkgs.runCommand "dsh-local-presets-cordis.patch.yml"
  {
    nativeBuildInputs = [ pkgs.yq-go ];
    MIN_UP = "${webAppPresets}/minimal.patch.yml";
    PTC_UP = "${webAppPresets}/ptc.patch.yml";
    MIN_EX = presetsDir + "/my-minimal/extras.cordis.yml";
    MIN_META = presetsDir + "/my-minimal/preset.yml";
    PTC_EX = presetsDir + "/my-ptc/extras.cordis.yml";
    PTC_META = presetsDir + "/my-ptc/preset.yml";
    ROUTER_COMP = presetsDir + "/router-standard/agent.cordis.yml";
    ROUTER_META = presetsDir + "/router-standard/preset.yml";
    MYROUTER_COMP = presetsDir + "/my-router-standard/agent.cordis.yml";
    MYROUTER_META = presetsDir + "/my-router-standard/preset.yml";
  }
  ''
    set -euo pipefail

    # 两份 shipped preset 都必须是「恰好一条 agent-preset 声明」的形状。
    for patch in "$MIN_UP" "$PTC_UP"; do
      yq -e '.[0].insert[0].name == "@deepseek-ai/dsh-agent-preset"' "$patch" >/dev/null || {
        printf 'dsh-local presets: %s is not a shipped preset declaration patch\n' "$patch" >&2
        exit 1
      }
    done

    # ptc 的 compaction 组里必须恰好一条 compaction-basic —— 本地要把它换成
    # pi-blackhole 的确定性后端。多于一条说明上游改了结构，需人工决定怎么换。
    compactionRows=$(yq -r '[.. | select(tag == "!!map") | select(.id? == "compaction-basic")] | length' "$PTC_UP")
    [ "$compactionRows" -eq 1 ] || {
      printf 'dsh-local presets: shipped ptc has %s compaction-basic rows, expected exactly 1\n' "$compactionRows" >&2
      exit 1
    }

    # 这一行是整体替换（不是逐字段改写）。shipped 行一旦多出别的键，必须显式决定
    # 保留还是丢弃，否则会被替换静默吞掉。加键即构建失败。
    ptcCompactionKeys=$(yq -r '[.. | select(tag == "!!map") | select(.id? == "compaction-basic") | keys] | flatten | unique | join(" ")' "$PTC_UP")
    [ "$ptcCompactionKeys" = "id name" ] || {
      printf 'dsh-local presets: shipped ptc compaction-basic row has keys [%s], expected only id/name; update the replacement below accordingly\n' "$ptcCompactionKeys" >&2
      exit 1
    }

    ${rewrite "minimalExtras" "minimal-extras.yml" "$MIN_EX"}
    ${rewrite "ptcExtras" "ptc-extras.yml" "$PTC_EX"}
    ${rewrite "router" "router-agent.yml" "$ROUTER_COMP"}
    ${rewrite "myRouter" "my-router-agent.yml" "$MYROUTER_COMP"}

    # 重写不应给任何 map 补出 `name: null`。这是 yq `|=` 路径赋值的静默副作用：
    # 路径里对不存在的键取值会创建该键（见 rewrite 上方的说明）。少了这层校验，
    # 损坏会被原样搬进产物，直到运行期插件 schema 报 "unknown key name" 才炸 ——
    # 而 build 与 --dump-config 都是通过的。
    for f in minimal-extras.yml ptc-extras.yml router-agent.yml my-router-agent.yml; do
      ${checkNoStrayName "$TMPDIR/$f"}
    done

    # 重写后不应残留 ./ 说明符。
    for f in minimal-extras.yml ptc-extras.yml router-agent.yml my-router-agent.yml; do
      left=$(yq -r '[.. | select(tag == "!!map") | .name | select(tag == "!!str") | select(test("^\\./"))] | length' "$TMPDIR/$f")
      [ "$left" -eq 0 ] || {
        printf 'dsh-local presets: %s still has %s relative specifier(s) after rewrite; add them to rewrites\n' "$f" "$left" >&2
        exit 1
      }
    done

    yq -n -P '
      load(strenv(MIN_UP)) as $minUp | load("'"$TMPDIR"'/minimal-extras.yml") as $minEx | load(strenv(MIN_META)) as $minMeta |
      load(strenv(PTC_UP)) as $ptcUp | load("'"$TMPDIR"'/ptc-extras.yml") as $ptcEx | load(strenv(PTC_META)) as $ptcMeta |
      load("'"$TMPDIR"'/router-agent.yml") as $routerComp | load(strenv(ROUTER_META)) as $routerMeta |
      load("'"$TMPDIR"'/my-router-agent.yml") as $myRouterComp | load(strenv(MYROUTER_META)) as $myRouterMeta |

      # ptc 的 compaction-basic 整行换成 pi-blackhole 的确定性后端并钉住压力阈值。
      # 对象字面量整体替换（yq 的链式赋值在这里会静默丢掉新建的 config 键）。
      # thresholdRatio 0.4（上游 0.8 / 官方 router-standard 0.55）：与 my-minimal、
      # my-router-standard 统一，改这里要一起改那两处。
      ($ptcUp | (.. | select(tag == "!!map") | select(.id? == "compaction-basic")) |=
        {"id": "blackhole-compact", "name": ${builtins.toJSON blackholeCompaction}, "config": {"thresholdRatio": 0.4}}) as $ptcSwapped |

      [
        { "insert": [ { "id": "preset-my-minimal", "name": "@deepseek-ai/dsh-agent-preset",
            "config": { "id": "my-minimal", "name": $minMeta.name, "description": $minMeta.description,
                        "order": $minMeta.order, "plugins": ($minUp[0].insert[0].config.plugins + $minEx) } } ] },
        { "insert": [ { "id": "preset-my-ptc", "name": "@deepseek-ai/dsh-agent-preset",
            "config": { "id": "my-ptc", "name": $ptcMeta.name, "description": $ptcMeta.description,
                        "order": $ptcMeta.order, "plugins": ($ptcSwapped[0].insert[0].config.plugins + $ptcEx) } } ] },
        { "insert": [ { "id": "preset-router-standard", "name": "@deepseek-ai/dsh-agent-preset",
            "config": { "id": "router-standard", "name": $routerMeta.name, "description": $routerMeta.description,
                        "order": $routerMeta.order, "plugins": $routerComp } } ] },
        { "insert": [ { "id": "preset-my-router-standard", "name": "@deepseek-ai/dsh-agent-preset",
            "config": { "id": "my-router-standard", "name": $myRouterMeta.name, "description": $myRouterMeta.description,
                        "order": $myRouterMeta.order, "plugins": $myRouterComp } } ] }
      ]
    ' > $out

    # 最终产物再校验一次。上面校验的是四个重写产物，而 $out 还经过 load + `|=` 替换 +
    # 数组拼接 —— 每一步都可能重新引入 `name: null`（yq 的 `|=` 路径赋值是主要来源）。
    # 这里炸掉比运行期「4 份 preset 全部 Failed to load」好定位得多。
    ${checkNoStrayName "$out"}
  ''
