#!/usr/bin/env bash
# 更新 packages/codebuddy-code 到 npm 最新版（或指定版本）：
#   ./update.sh [version]
# 只改主包的 version/hash；@lydell/node-pty 版本变了才需要手动改
# nodePtyVersion 与各平台 hash（npm view @lydell/node-pty version）。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

file=default.nix
version="${1:-$(npm view @tencent-ai/codebuddy-code version)}"
url="https://registry.npmjs.org/@tencent-ai/codebuddy-code/-/codebuddy-code-${version}.tgz"
hash="$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -r .hash)"

echo "codebuddy-code $version $hash"

python3 - "$file" "$version" "$hash" <<'PY'
import re
import sys

path, version, digest = sys.argv[1:4]
src = open(path).read()
src, n1 = re.subn(r'version = "[^"]+";', f'version = "{version}";', src, count=1)
src, n2 = re.subn(
    r'(codebuddy-code-\$\{version\}\.tgz";\s*hash = ")[^"]+(")',
    lambda m: m.group(1) + digest + m.group(2),
    src,
    count=1,
)
assert n1 == 1 and n2 == 1, "default.nix 结构已变，update.sh 需要同步修改"
open(path, "w").write(src)
PY
