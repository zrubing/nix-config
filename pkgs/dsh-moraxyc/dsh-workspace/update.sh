#!/usr/bin/env bash
# dsh 上游更新脚本（pkgs/dsh-moraxyc 源码构建链，deepseek-ai/deepseek-harness）
#
# 用法:
#   ./update.sh                    # 升级到上游最新 dsh-v* tag（默认）
#   ./update.sh 0.1.3-rc.1         # 升级到指定版本（对应 tag dsh-v0.1.3-rc.1）
#   ./update.sh --ref dsh-v0.1.3-rc.1   # 同指定版本（--ref 接受 tag / refs/tags/<tag>）
#   ./update.sh --dry-run          # 只打印将要执行的动作，不写任何文件
#   ./update.sh --build            # 升级后自动跑 nix build .#dsh-source 验证
#   ./update.sh --force            # 目标版本与当前相同时仍重跑（修复漂移）
#
# 流程:
#   1. git ls-remote 解析目标 rev（tag -> commit）
#   2. nix-prefetch-url 拉 GitHub archive：同时取 fetchFromGitHub 的 SRI hash 和
#      上游源码树（archive 内容与 fetchFromGitHub/fetchzip 一致，a1/a2 实测相等）
#   3. nix flake update deepseek-harness-src 更新 flake.lock（agent-presets 输入
#      与 kernel 同 rev；若上游 master 已领先 tag 会告警）
#   4. 上游 pnpm-lock.yaml -> pnpm-lock.json（yq-go 取自本 flake 锁定的 nixpkgs）
#   5. 更新 dsh-workspace/package.nix：version / hash / DSH_CLIENT_COMMIT_HASH / 注释
#   6. 同步 dsh-landlock-run 版本（上游 native/landlock-run/package.json 变化时）
#   7. 同步 modules/home/dsh/default.nix 的版本备注
#   8. 校验：flake.lock 落点 rev、nix eval dsh-source.version；--build 时全量构建
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

pkg_dir="pkgs/dsh-moraxyc/dsh-workspace"
pkg_file="$pkg_dir/package.nix"
lock_json="$pkg_dir/pnpm-lock.json"
landlock_file="pkgs/dsh-moraxyc/dsh-landlock-run/package.nix"
module_file="modules/home/dsh/default.nix"
upstream="https://github.com/deepseek-ai/deepseek-harness.git"

dry_run=0
do_build=0
force=0
target="latest"
ref=""

usage() {
  sed -n '3,12p' "$0" | sed 's/^# {0,1}//'
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

cur_ver="$(sed -n 's/^  version = "\([^"]*\)";$/\1/p' "$pkg_file" | head -1)"
[ -n "$cur_ver" ] || die "cannot read current version from $pkg_file"

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
  echo "update-dsh: package.nix 已是 $cur_ver 但 flake.lock 不在 $tag，继续修正" >&2
fi

# ── 2. archive：SRI hash + 上游源码树 ─────────────────────────────────────────
archive_url="https://github.com/deepseek-ai/deepseek-harness/archive/$rev.tar.gz"
prefetch_out="$(nix-prefetch-url --unpack --print-path --type sha256 "$archive_url" 2>/dev/null | sed -n '1,2p' || true)"
raw_hash="$(printf '%s
' "$prefetch_out" | sed -n '1p')"
src="$(printf '%s
' "$prefetch_out" | sed -n '2p')"
[ -n "$raw_hash" ] || die "nix-prefetch-url failed for $archive_url"
sri="$(nix hash convert --hash-algo sha256 --to sri "$raw_hash" 2>/dev/null \
  || { nix to-base64 "$raw_hash" 2>/dev/null | sed 's|^|sha256-|' || true; })"
[ -n "$sri" ] || die "cannot convert archive hash to SRI"
# --unpack 的 store 路径就是解包后的源码树（单根目录已剥离，与 fetchFromGitHub 一致）
[ -f "$src/pnpm-lock.yaml" ] || die "unpacked source has no pnpm-lock.yaml: $src"
echo "update-dsh: source hash $sri"

# ── 3. flake.lock（agent-presets 输入与 kernel 同 rev）────────────────────────
run_step nix flake update deepseek-harness-src
if grep -q "\"rev\": \"$rev\"" flake.lock; then
  echo "update-dsh: flake.lock deepseek-harness-src -> $rev"
else
  echo "update-dsh: WARN flake.lock 落点不是 $tag（master 已领先）；" >&2
  echo "update-dsh:      agent-presets 输入将比 kernel 新，重建前可自行核对" >&2
fi

# ── 4. pnpm-lock.json（yq-go 用本 flake 锁定的 nixpkgs）───────────────────────
yq_bin="$(nix build --no-link --print-out-paths --impure \
  --expr 'let f = builtins.getFlake (toString ./.); in f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem}.yq-go' \
  2>/dev/null || true)"
[ -n "$yq_bin" ] || die "cannot obtain yq-go from the locked nixpkgs input"
if [ "$dry_run" = 1 ]; then
  echo "[dry-run] $yq_bin/bin/yq -o=json -I=0 $src/pnpm-lock.yaml > $lock_json"
else
  "$yq_bin/bin/yq" -o=json -I=0 "$src/pnpm-lock.yaml" > "$lock_json"
fi

# ── 5. dsh-workspace/package.nix ──────────────────────────────────────────────
pkg_sed() { # pattern file
  if [ "$dry_run" = 1 ]; then
    echo "[dry-run] sed -i -E '$1' $2"
  else
    sed -i -E "$1" "$2"
  fi
}
pkg_sed "s|^  version = \".*\";$|  version = \"$new_ver\";|" "$pkg_file"
pkg_sed "s|hash = \"sha256-[^\"]*\";|hash = \"$sri\";|" "$pkg_file"
pkg_sed "s|^  env\\.DSH_CLIENT_COMMIT_HASH = .*;$|  env.DSH_CLIENT_COMMIT_HASH = \"$rev\";|" "$pkg_file"
pkg_sed "s|拉 dsh-v$cur_ver|拉 dsh-v$new_ver|" "$pkg_file"

# ── 6. dsh-landlock-run 版本同步 ──────────────────────────────────────────────
land_new="$("$yq_bin/bin/yq" -r '.version' "$src/native/landlock-run/package.json" 2>/dev/null | head -1 || true)"
land_cur="$(sed -n 's/^  version = "\([^"]*\)";$/\1/p' "$landlock_file" | head -1)"
if [ -n "$land_new" ] && [ "$land_new" != "$land_cur" ]; then
  pkg_sed "s|^  version = \"[^\"]*\";$|  version = \"$land_new\";|" "$landlock_file"
  echo "update-dsh: dsh-landlock-run $land_cur -> $land_new"
fi

# ── 7. 模块版本备注 ───────────────────────────────────────────────────────────
if grep -q "追 \(main\|master\)/$cur_ver" "$module_file"; then
  pkg_sed "s@追 (main|master)/$cur_ver@追 master/$new_ver@" "$module_file"
fi

# ── 8. 校验 ───────────────────────────────────────────────────────────────────
if [ "$dry_run" = 0 ]; then
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
git status --porcelain | sed 's|^|  |' | grep -E 'flake.lock|dsh-workspace|dsh-landlock-run|modules/home/dsh/default.nix' || true
