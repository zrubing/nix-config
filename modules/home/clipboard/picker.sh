# cliphist + fuzzel 的剪贴板选择器。
#
# 文本条目直接列；图片条目用 cliphist decode 生成 PNG 缩略图，再借 fuzzel
# dmenu 的 rofi 图标协议（\0icon\x1f<path>）显示预览。
#
# 注意两件事：
#   1. nixpkgs 的 cliphist 0.7.0 没有 `list -fields`（master 的功能未发布），
#      只能按 preview 文本前缀 `[[ binary data ... ]]` 识别图片条目。
#   2. fuzzel 的图标高度等于行高，所以有图片时统一抬 line-height；
#      纯文本历史保持原来的紧凑行高。

set -euo pipefail

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/cliphist/thumbs"
mkdir -p "$cache_dir"

list="$(cliphist list || true)"
if [[ -z "$list" ]]; then
  fuzzel --dmenu --prompt-only "剪贴板为空" || true
  exit 0
fi

fuzzel_args=(--dmenu --no-sort --counter --placeholder "搜索剪贴板…")

if [[ "$list" == *$'\t[[ binary data '* ]]; then
  fuzzel_args+=(
    --line-height "${CLIPHIST_PREVIEW_HEIGHT:-96}px"
    --lines "${CLIPHIST_PREVIEW_LINES:-6}"
  )
fi

image_preview_re='^\[\[ binary data .* (png|jpeg|jpg|gif|bmp|tiff|webp) [0-9]+x[0-9]+ \]\]$'

emit_entries() {
  local id preview_text thumb tmp
  while IFS=$'\t' read -r id preview_text; do
    [[ -n "$id" ]] || continue

    if [[ "$preview_text" =~ $image_preview_re ]]; then
      thumb="$cache_dir/$id.png"
      if [[ ! -f "$thumb" ]]; then
        tmp="$(mktemp "$cache_dir/$id.XXXXXX")"
        if cliphist decode "$id" >"$tmp" &&
          magick "${tmp}[0]" -thumbnail 256x256 "png:$thumb"; then
          rm -f "$tmp"
        else
          # 转换失败就退化成普通文本条目，不要让整个选择器挂掉。
          rm -f "$tmp" "$thumb"
          printf '%s\t%s\n' "$id" "$preview_text"
          continue
        fi
      fi
      printf '%s\t%s\0icon\x1f%s\n' "$id" "$preview_text" "$thumb"
    else
      printf '%s\t%s\n' "$id" "$preview_text"
    fi
  done <<<"$list"
}

selection="$(emit_entries | fuzzel "${fuzzel_args[@]}")" || exit 0
[[ -n "$selection" ]] || exit 0

id="${selection%%$'\t'*}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cliphist decode "$id" >"$tmp"
mime="$(file --brief --mime-type "$tmp")"
if [[ "$mime" == image/* ]]; then
  wl-copy --type "$mime" <"$tmp"
else
  wl-copy <"$tmp"
fi

# 清掉已经不在历史里的缩略图（cliphist 满 750 条会淘汰旧条目）。
declare -A live=()
while IFS=$'\t' read -r id _; do
  if [[ -n "$id" ]]; then
    live["$id"]=1
  fi
done <<<"$list"

for thumb in "$cache_dir"/*.png; do
  [[ -e "$thumb" ]] || continue
  id="${thumb##*/}"
  id="${id%.png}"
  [[ -n "${live[$id]:-}" ]] || rm -f "$thumb"
done
