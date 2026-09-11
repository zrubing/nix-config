#!/usr/bin/env bash
# dsh 上游更新脚本（pkgs/dsh-moraxyc 源码构建链，deepseek-ai/deepseek-harness）
#
# 用法:
#   ./update.sh                    # 升级到上游最新 dsh-v* tag（默认）
#   ./update.sh 0.1.5-rc.2         # 升级到指定版本（对应 tag dsh-v0.1.5-rc.2）
#   ./update.sh --ref dsh-v0.1.5-rc.2   # 同指定版本（--ref 接受 tag / refs/tags/<tag>）
#   ./update.sh --dry-run          # 只打印将要执行的动作，不写任何文件
#   ./update.sh --build            # 升级后自动跑 nix build .#dsh-source 验证
#   ./update.sh --force            # 目标版本与当前相同时仍重跑（修复漂移）
#
# 流程:
#   1. git ls-remote 解析目标 rev（tag -> commit）
#   2. 把 flake.nix 的 deepseek-harness-src input ref 改到目标 tag
#   3. nix flake update deepseek-harness-src 更新 flake.lock（版本唯一事实来源）
#   4. 从 flake input 取上游源码树 store path，按需重生成 pnpm-lock.json
#   5. 同步 dsh-landlock-run 版本（上游 native/system/packages/entry/package.json 变化时）
#   6. 同步各处版本备注（flake.nix / modules/home/dsh / homes/jojo）
#   7. 校验：flake.lock 落点 rev、旧版本字样无残留、nix eval dsh-source.version；--build 时全量构建
#
# 注意：dsh-workspace/package.nix 不再含 version/hash/commit 常量——version 取自源码
# package.json、DSH_CLIENT_COMMIT_HASH 取自 flake.lock，升级入口只剩 flake.nix 的 ref。
# 因此本脚本不再 sed 该文件（历史上那 4 条 sed 在重构后全部失配，且第一步就读不到
# version 直接退出，等于升级链路整体失效）。
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

pkg_dir="pkgs/dsh-moraxyc/dsh-workspace"
lock_json="$pkg_dir/pnpm-lock.json"
landlock_file="pkgs/dsh-moraxyc/dsh-landlock-run/package.nix"
flake_file="flake.nix"
module_file="modules/home/dsh/default.nix"
home_file="homes/x86_64-linux/jojo/default.nix"
upstream="https://github.com/deepseek-ai/deepseek-harness.git"

dry_run=0
do_build=0
force=0
target="latest"
ref=""

usage() {
  sed -n '3,11p' "$0" | sed 's/^# {0,1}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --build) do_build=1 ;;
    --force) force=1 ;;
    --ref) ref="$2"; shift ;;
    --help | -h) usage; exit 0 ;;
    --*) echo "unknown option: $1" >&2; exit 2 ;;
    *) target="$1" ;;
  esac
  shift
done

die() {
  echo "update-dsh: $*" >&2
  exit 1
}

# 非 dry-run 时执行 $@；dry-run 时只打印。写文件的操作都必须走这里。
run_step() {
  if [ "$dry_run" = 1 ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

# 当前版本的唯一事实来源 = flake.lock 里 deepseek-harness-src 的锁定 ref（dsh-v<version>）。
cur_ver="$(sed -n 's|.*"ref": "dsh-v\([^"]*\)".*|\1|p' flake.lock | head -1)"
[ -n "$cur_ver" ] || die "cannot read current dsh version from flake.lock (deepseek-harness-src ref)"

# ── 1. 目标 tag / rev ─────────────────────────────────────────────────────────
tag="$target"
if [ -n "$ref" ]; then
  case "$ref" in
    refs/tags/*) tag="${ref#refs/tags/}" ;;
    *) tag="$ref" ;;
  esac
elif [ "$target" = "latest" ]; then
  tag="$(git ls-remote --refs "$upstream" 'refs/tags/dsh-v*' \
    | sed 's|.*refs/tags/||' | sort -V | tail -1 || true)"
  [ -n "$tag" ] || die "no upstream dsh-v* tags found"
else
  # 位置参数是版本号：按用法映射到 dsh-v<version> tag（容忍已带前缀的写法）
  case "$target" in
    dsh-v*) tag="$target" ;;
    *) tag="dsh-v$target" ;;
  esac
fi

new_ver="${tag#dsh-v}"
rev="$(git ls-remote --refs "$upstream" "refs/tags/$tag" | cut -f1 || true)"
[ -n "$rev" ] || die "upstream ref '$tag' not found"

echo "update-dsh: $cur_ver -> $new_ver (tag $tag, rev $rev)"

if [ "$force" = 0 ] && [ "$new_ver" = "$cur_ver" ]; then
  if grep -q "\"rev\": \"$rev\"" flake.lock; then
    echo "update-dsh: already at $cur_ver ($tag); nothing to do (use --force to redo)"
    exit 0
  fi
  echo "update-dsh: flake.lock 已是 $cur_ver 但不在 $tag，继续修正" >&2
fi

# ── 2/3. flake.nix ref + flake.lock ───────────────────────────────────────────
# input ref 是唯一可写的版本入口；先改 ref 再 update，下一句才会跟着新 tag 走。
if [ "$dry_run" = 1 ]; then
  echo "[dry-run] sed -i -E 's|ref=dsh-v$cur_ver|ref=dsh-v$new_ver|' $flake_file"
else
  sed -i -E "s|ref=dsh-v$cur_ver|ref=dsh-v$new_ver|" "$flake_file"
  grep -q "ref=dsh-v$new_ver" "$flake_file" || die "flake.nix input ref 未改到 dsh-v$new_ver"
fi

run_step nix flake update deepseek-harness-src
if grep -q "\"rev\": \"$rev\"" flake.lock; then
  echo "update-dsh: flake.lock deepseek-harness-src -> $rev"
else
  echo "update-dsh: WARN flake.lock 落点不是 $tag（master 已领先）；" >&2
  echo "update-dsh:      agent-presets 输入将比 kernel 新，重建前可自行核对" >&2
fi

# ── 4. 上游源码树 + pnpm-lock.json ───────────────────────────────────────────
# 源码树直接取 flake input 的 store path（flake.lock 已更新），不重复下载 archive。
src=""
if [ "$dry_run" = 0 ]; then
  src="$(nix eval --impure --raw \
    --expr 'builtins.toString (builtins.getFlake (toString ./.)).inputs.deepseek-harness-src' 2>/dev/null || true)"
fi
if [ "$dry_run" = 1 ]; then
  echo "[dry-run] 从 flake input 解析上游源码树（store path）并重生成 $lock_json"
else
  [ -f "$src/pnpm-lock.yaml" ] || die "flake input 源码树里没有 pnpm-lock.yaml: ${src:-<eval failed>}"
  yq_bin="$(nix build --no-link --print-out-paths --impure \
    --expr 'let f = builtins.getFlake (toString ./.); in f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem}.yq-go' \
    2>/dev/null || true)"
  [ -n "$yq_bin" ] || die "cannot obtain yq-go from the locked nixpkgs input"
  "$yq_bin/bin/yq" -o=json -I=0 "$src/pnpm-lock.yaml" > "$lock_json"
fi

# ── 5. dsh-landlock-run 版本同步 ──────────────────────────────────────────────
land_new=""
[ "$dry_run" = 1 ] || land_new="$("$yq_bin/bin/yq" -r '.version' "$src/native/system/packages/entry/package.json" 2>/dev/null | head -1 || true)"
land_cur="$(sed -n 's/^  version = "\([^"]*\)";$/\1/p' "$landlock_file" | head -1)"
if [ -n "$land_new" ] && [ "$land_new" != "$land_cur" ]; then
  if [ "$dry_run" = 1 ]; then
    echo "[dry-run] dsh-landlock-run $land_cur -> $land_new in $landlock_file"
  else
    sed -i -E "s|^  version = \"[^\"]*\";$|  version = \"$land_new\";|" "$landlock_file"
  fi
  echo "update-dsh: dsh-landlock-run $land_cur -> $land_new"
fi

# ── 6. 版本备注同步 ───────────────────────────────────────────────────────────
note_sed() { # pattern file
  if [ "$dry_run" = 1 ]; then
    echo "[dry-run] sed -i -E '$1' $2"
  else
    sed -i -E "$1" "$2"
  fi
}
note_sed "s|当前固定在 tag dsh-v$cur_ver|当前固定在 tag dsh-v$new_ver|" "$flake_file"
note_sed "s|当前锁 tag dsh-v$cur_ver|当前锁 tag dsh-v$new_ver|" "$module_file"
note_sed "s|用源码构建的 dsh $cur_ver|用源码构建的 dsh $new_ver|" "$home_file"

# ── 7. 校验 ───────────────────────────────────────────────────────────────────
if [ "$dry_run" = 0 ]; then
  # 旧版本字样残留 = 注释漂移（不致命但会误导），显式报出来。
  stale="$(grep -rn "$cur_ver" "$flake_file" "$module_file" "$home_file" "$landlock_file" 2>/dev/null || true)"
  [ -z "$stale" ] || echo "update-dsh: WARN 仍有 $cur_ver 字样未同步：
$stale" >&2

  system="$(nix eval --raw --impure --expr 'builtins.currentSystem')"
  actual="$(nix eval --raw ".#packages.$system.dsh-source.version" 2>/dev/null || true)"
  [ "$actual" = "$new_ver" ] || die "flake eval mismatch: dsh-source.version = ${actual:-<eval failed>}"
  echo "update-dsh: eval dsh-source.version = $actual"
  if [ "$do_build" = 1 ]; then
    nix build ".#dsh-source"
    echo "update-dsh: nix build .#dsh-source ok"
  else
    echo "update-dsh: 下一步验证: nix build .#dsh-source   （或重跑 --build）"
  fi
fi

echo "update-dsh: done. 变更文件:"
git status --porcelain | sed 's|^|  |' | grep -E 'flake.lock|flake.nix|dsh-workspace|dsh-landlock-run|modules/home/dsh/default.nix|homes/x86_64-linux/jojo' || true
