#!/usr/bin/env bash
# 双向同步 git 权威源与运行时 skill 目录：
#   源:   /home/jojo/nix-config/.pi/skill-sources（nix-config 仓库，git 管理）
#   live: ~/.pi/agent/skills（pi 运行时加载）
#
# 用法:
#   skill-sync.sh check                # 对比所有 skill，行协议输出
#   skill-sync.sh check <skill>        # 只对比一个
#   skill-sync.sh pull <skill>         # 源 → live（应用源里的改动）
#   skill-sync.sh push <skill>         # live → 源（把本地迭代回流 git）
#
# 输出行协议（agent 可解析）:
#   IN_SYNC:<name>       无差异
#   CHANGED:<name>       有差异，unified diff 直到 END_DIFF 行（方向: live → 源）
#   MISSING:<name>       源有、live 没有（可 pull）
#   LOCAL_ONLY:<name>    live 有、源没有（本地私有，忽略）
#   ALL_IN_SYNC          全部无差异
set -euo pipefail

SKILL_SRC="${SKILL_SRC:-/home/jojo/nix-config/.pi/skill-sources}"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.pi/agent/skills}"

cmd="${1:?Usage: skill-sync.sh check|pull|push <skill>}"
shift

check_one() {
  local src_dir="$1" local_dir="$2" name
  name=$(basename "$src_dir")
  if [ ! -d "$local_dir" ]; then
    echo "MISSING:$name"
    return 1
  fi
  if diff -rq "$src_dir" "$local_dir" >/dev/null 2>&1; then
    echo "IN_SYNC:$name"
    return 0
  fi
  echo "CHANGED:$name"
  diff -ru "$local_dir" "$src_dir" 2>/dev/null || true
  echo "END_DIFF"
  return 1
}

case "$cmd" in
  check)
    has_changes=false
    local_only=0
    if [ $# -gt 0 ]; then
      for name in "$@"; do
        check_one "$SKILL_SRC/$name" "$SKILLS_DIR/$name" && continue
        has_changes=true
      done
    else
      for dir in "$SKILL_SRC"/*/; do
        [ -d "$dir" ] || continue
        check_one "$dir" "$SKILLS_DIR/$(basename "$dir")" && continue
        has_changes=true
      done
      for dir in "$SKILLS_DIR"/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        if [ ! -d "$SKILL_SRC/$name" ]; then
          echo "LOCAL_ONLY:$name"
          local_only=$((local_only + 1))
        fi
      done
    fi
    if [ "$has_changes" = false ] && [ "$local_only" -eq 0 ]; then
      echo "ALL_IN_SYNC"
    elif [ "$has_changes" = false ]; then
      echo "ALL_IN_SYNC (local-only: $local_only)"
    fi
    ;;
  pull)
    name="${1:?Usage: skill-sync.sh pull <skill>}"
    [ -d "$SKILL_SRC/$name" ] || { echo "ERROR: skill '$name' not in $SKILL_SRC"; exit 1; }
    mkdir -p "$SKILLS_DIR/$name"
    rsync -a "$SKILL_SRC/$name/" "$SKILLS_DIR/$name/"
    echo "OK: pulled $name"
    ;;
  push)
    name="${1:?Usage: skill-sync.sh push <skill>}"
    [ -d "$SKILLS_DIR/$name" ] || { echo "ERROR: skill '$name' not in $SKILLS_DIR"; exit 1; }
    mkdir -p "$SKILL_SRC/$name"
    rsync -a "$SKILLS_DIR/$name/" "$SKILL_SRC/$name/"
    echo "OK: pushed $name"
    ;;
  *)
    echo "Usage: skill-sync.sh check|pull|push <skill>" >&2
    exit 1
    ;;
esac
