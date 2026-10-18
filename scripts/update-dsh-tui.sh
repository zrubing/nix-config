#!/usr/bin/env bash
# 升级上游 dsh-TUI：换 tag、验补丁、回填三个 hash、跑契约自检。
#
#   ./scripts/update-dsh-tui.sh v0.16.0
#   ./scripts/update-dsh-tui.sh v0.16.0 --no-verify      # 只到构建通过
#
# 能自动的部分全自动；不能自动的只有一件事——补丁冲突。冲突时脚本会在
# `.work/update-<tag>` 留下一棵 conflict 树并退出 3，不会把半成品写进仓库。
#
# 退出码：0 完成 / 2 用法或前置条件 / 3 补丁冲突需人工 / 4 构建失败（非 hash）
set -euo pipefail

readonly PKG=packages/dsh-tui-remote
readonly NIX_FILE="$PKG/default.nix"
readonly PATCH="$PKG/remote-mode.patch"
readonly UPSTREAM=https://github.com/ccch1mneyyy/dsh-TUI
readonly MAX_HASH_ROUNDS=5

die() { printf '\n\033[31m✗ %s\033[0m\n' "$1" >&2; exit "${2:-4}"; }
step() { printf '\n\033[36m▸ %s\033[0m\n' "$1"; }
ok() { printf '\033[32m  ✓ %s\033[0m\n' "$1"; }

tag="${1:-}"
verify=1
for arg in "$@"; do [[ "$arg" == "--no-verify" ]] && verify=0; done

if [[ -z "$tag" || "$tag" == --* ]]; then
  printf 'usage: %s <tag> [--no-verify]\n  e.g. %s v0.16.0\n' "$0" "$0" >&2
  exit 2
fi

repo=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)
cd "$repo"
[[ -f "$NIX_FILE" && -f "$PATCH" ]] || die "找不到 $NIX_FILE 或 $PATCH（要在 nix-config 仓库里跑）" 2
command -v nix >/dev/null || die 'PATH 上没有 nix' 2

# ── 1. 改 tag ────────────────────────────────────────────────────────────────
step "目标版本 $tag"
current=$(sed -n 's/^  tag = "\(v[^"]*\)";.*/\1/p' "$NIX_FILE")
if [[ "$current" == "$tag" ]]; then
  ok "tag 已是 $tag（重跑构建/自检）"
else
  sed -i "s/^  tag = \"$current\";/  tag = \"$tag\";/" "$NIX_FILE"
  sed -i 's/hash = "sha256-[^"]*"; # SRC_HASH/hash = lib.fakeHash; # SRC_HASH/' "$NIX_FILE"
  ok "$current → $tag，源码 hash 已重置"
fi

# ── 2. 补丁能否套到新 tag 上 ─────────────────────────────────────────────────
step "检查 remote-mode.patch 是否可套用"
work=".work/update-${tag//\//-}"
rm -rf "$work"
git clone -q --depth 1 --branch "$tag" --recurse-submodules "$UPSTREAM" "$work" 2>/dev/null \
  || die "clone $tag 失败（tag 不存在或网络不通）" 2

if git -C "$work" apply --check "$repo/$PATCH" 2>/dev/null; then
  ok "补丁干净套用"
else
  printf '\033[33m  补丁与新版本冲突，尝试三方合并…\033[0m\n'
  if git -C "$work" apply --3way "$repo/$PATCH" 2>/dev/null; then
    ok "三方合并成功（无冲突）"
  else
    printf '\n\033[31m补丁冲突，需要人工处理：\033[0m\n'
    printf '  1. cd %s && git status   # 看 conflict 文件\n' "$work"
    printf '  2. 解决后把改动并回 patch：\n'
    printf '       git -C %s add -N src/dsh-adapter/remote\n' "$work"
    printf '       git -C %s diff > %s\n' "$work" "$repo/$PATCH"
    printf '  3. 重跑：%s %s\n\n' "$0" "$tag"
    exit 3
  fi
fi

# ── 3. 回填 hash（build 一次抄一次，最多 MAX_HASH_ROUNDS 轮） ────────────────
step "构建并回填 hash"
for round in $(seq 1 "$MAX_HASH_ROUNDS"); do
  printf '  · 第 %s 轮\n' "$round"
  output=$(nix build .#dsh-tui-remote 2>&1 | grep -vE 'attic\.|devenv\.cachix|cachix\.org' || true)

  if [[ -z "$output" ]] || ! grep -q 'error:' <<<"$output"; then
    ok "构建通过"
    break
  fi

  if grep -q 'hash mismatch' <<<"$output"; then
    drv=$(grep -o "/nix/store/[a-z0-9]*-[a-z0-9-]*\.drv" <<<"$output" | head -1)
    got=$(grep -m1 'got:' <<<"$output" | awk '{print $2}')
    [[ -n "$got" ]] || die "解析不到 hash（drv=$drv）"
    case "$drv" in
      *vendor*) field=outputHash; marker=VENDOR_HASH ;;
      *source*|*dsh-TUI*) field=hash; marker=SRC_HASH ;;
      *) field=outputHash; marker=ROOT_HASH ;;
    esac
    sed -i "s|$field = \"sha256-[^\"]*\"; # $marker|$field = \"$got\"; # $marker|" "$NIX_FILE"
    sed -i "s|$field = lib.fakeHash; # $marker|$field = \"$got\"; # $marker|" "$NIX_FILE"
    ok "$marker ← $got"
    [[ "$round" == "$MAX_HASH_ROUNDS" ]] && die "hash 轮次用尽，仍有不匹配" 4
    continue
  fi

  printf '%s\n' "$output" | grep -vE '^\s*$' | tail -25
  die "构建失败（非 hash 问题），完整日志：nix log \$(上面的 drv)" 4
done

# ── 4. 契约自检 ─────────────────────────────────────────────────────────────
if [[ "$verify" == 1 ]]; then
  step "契约自检（描述符 / 方法名 / 事件字段 / compact）"
  tree="$(readlink -f result)/libexec"
  if command -v dsh-tui-remote-verify >/dev/null; then
    DSH_TUI_REMOTE_TREE="$tree" dsh-tui-remote-verify || die "契约自检未通过——上游改了客户端依赖的面，见 docs §30" 4
    ok "自检通过"
  else
    # 还没切代时 PATH 上没有包装器：从已安装的启动器里取 shim 路径，直接跑自检。
    shim=$(sed -n 's/^export DSH_HOST_PACKAGE=\(.*\)$/\1/p' "$(command -v dsh-tui-remote 2>/dev/null || echo /dev/null)" | head -1)
    node=$(command -v node || true)
    if [[ -n "$shim" && -n "$node" ]]; then
      printf '\033[33m  用已安装启动器的 shim 直接跑：%s\033[0m\n' "$shim"
      # 目标宿主：$VERIFY_URL > 已配置的 DSH_TUI_REMOTE_URL > 脚本默认（127.0.0.1:3080）。
      verify_args=()
      [[ -n "${VERIFY_URL:-}" ]] && verify_args+=("$VERIFY_URL")
      PATH="$shim:$PATH" DSH_TUI_REMOTE_TREE="$tree" "$node" --expose-internals \
        "$tree/lib/types/dsh-adapter/remote/verify.js" "${verify_args[@]}" \
        || die "契约自检未通过——上游改了客户端依赖的面，见 docs §30" 4
      ok "自检通过"
    else
      printf '\033[33m  跳过：既没有 dsh-tui-remote-verify，也没有已安装的 dsh-tui-remote\033[0m\n'
    fi
  fi
fi

# ── 5. 收尾 ─────────────────────────────────────────────────────────────────
step "完成"
git --no-pager diff --stat -- "$PKG" || true
printf '\n产物：%s\n' "$(readlink -f result)"
printf '下一步：sudo nixos-rebuild switch --flake .#zen14\n'
printf '自检可随时重跑：dsh-tui-remote-verify\n'
