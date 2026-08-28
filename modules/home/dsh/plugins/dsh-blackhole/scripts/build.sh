#!/usr/bin/env bash
# Build the pi-blackhole core bundles that @jojo/dsh-blackhole imports.
#
# Single source of truth for the esbuild bundling of pi-blackhole's pure TS core.
# Both the Nix derivation (modules/home/dsh/plugins/dsh-blackhole/build.nix) and
# a plain `pnpm build` run this script. The only difference is where
# pi-blackhole's source comes from:
#   - Nix:      PI_BLACKHOLE_SRC=<flake input path>
#   - plain:    node_modules/pi-blackhole  (from the pi-blackhole devDependency)
#
# Output: lib/core/compile.js (deterministic compile()) and
#         lib/core/recall.js  (searchEntries/renderMessage/getTouchedFiles/
#                             getFileIndicators/parseDrillDown).
set -euo pipefail

SRC="${PI_BLACKHOLE_SRC:-node_modules/pi-blackhole}"
OUT=lib/core
mkdir -p "$OUT"

if [ ! -f "$SRC/src/core/summarize.ts" ]; then
  echo "pi-blackhole source not found at $SRC (set PI_BLACKHOLE_SRC or run \`pnpm install\`)" >&2
  exit 1
fi

# pi-tui's wrapTextWithAnsi is the ONE external runtime dep the compile core pulls;
# the adapter replaces it with a self-contained plain-text wrapper.
cat > "$OUT/tui-stub.mjs" <<'STUB'
export function wrapTextWithAnsi(text, maxChars = 120) {
  const plain = String(text).replace(/\x1b\[[0-9;]*[A-Za-z]/g, "");
  const words = plain.split(/(\s+)/);
  const lines = []; let line = "";
  for (const w of words) { if (!w) continue; if (line.length + w.length > maxChars && line.length > 0) { lines.push(line.trimEnd()); line = ""; } line += w; }
  if (line) lines.push(line.trimEnd());
  return lines.length > 0 ? lines : [plain];
}
export const visibleWidth = (s) => String(s).replace(/\x1b\[[0-9;]*[A-Za-z]/g, "").length;
STUB

# 1) deterministic compile() core  (alias target must be absolute)
STUB="$(pwd)/$OUT/tui-stub.mjs"
esbuild "$SRC/src/core/summarize.ts" \
  --bundle --platform=node --format=esm \
  --external:@earendil-works/pi-ai --external:typebox \
  --alias:@earendil-works/pi-tui="$STUB" \
  --outfile="$OUT/compile.js" --log-level=warning

# 2) recall search core
cat > "$OUT/recall-entry.ts" <<EOF
export { searchEntries, getFileIndicators, getTouchedFiles } from "$SRC/src/core/search-entries";
export { renderMessage } from "$SRC/src/core/render-entries";
export { parseDrillDown } from "$SRC/src/core/drill-down";
EOF
esbuild "$OUT/recall-entry.ts" \
  --bundle --platform=node --format=esm \
  --external:@earendil-works/pi-ai --external:typebox --external:@earendil-works/pi-tui \
  --outfile="$OUT/recall.js" --log-level=warning

rm -f "$OUT/tui-stub.mjs" "$OUT/recall-entry.ts"
