#!/usr/bin/env nix-shell
#!nix-shell -i bash -p nodePackages.npm nix-update nixpkgs-fmt

set -euo pipefail

version=$(npm view @fission-ai/openspec version)
echo "Updating open-spec to version: $version"

# 生成 lockfile
cd "$(dirname "${BASH_SOURCE[0]}")"
npm i --package-lock-only @fission-ai/openspec@"$version"
rm -f package.json

# Update version and hashes
cd -
nix-update openspec --version "$version"
