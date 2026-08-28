# The dsh-blackhole adapter package.
#
# Standalone Nix package that assembles the @jojo/dsh-blackhole dsh plugin:
#   - copies package.json + lib/ (the thin dsh adapters: compaction engine,
#     recall tool, observational-memory workers, /blackhole* commands)
#   - esbuild-bundles pi-blackhole's pure TS core (from the pi-blackhole-src
#     flake input) into lib/core/compile.js (deterministic compile()) and
#     lib/core/recall.js (search/render/drill) so dsh imports the real upstream
#     logic instead of a hand-ported snapshot. Upstream updates = re-pin the
#     flake rev + rebuild.
#   - adds a node_modules shim so bare @deepseek-ai/* imports resolve against
#     the mounted dsh package's own dependency tree.
#
# Consumed by modules/home/dsh/default.nix:
#   blackholePlugin = import ./plugins/dsh-blackhole/build.nix { inherit lib pkgs inputs dshNodeModules; };
# The preset then symlinks ~/.dsh/.agent-presets/my-minimal/dsh-blackhole ->
# this derivation and mounts "./dsh-blackhole/lib/compaction.js" (compaction
# isolate) and "./dsh-blackhole/lib/index.js" (agent scope).
{
  lib,
  pkgs,
  inputs,
  dshNodeModules,
  ...
}:
let
  pibh = inputs.pi-blackhole-src;
in
pkgs.runCommand "dsh-blackhole" {
  pname = "dsh-blackhole";
  version = "0.1.0";
  nativeBuildInputs = [ pkgs.esbuild ];
  meta = {
    description = "pi-blackhole adapter for DeepSeek Harness (deterministic compaction, recall, observational memory)";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
} ''
  set -euo pipefail
  mkdir -p $out/lib
  # 1) package sources (adapter logic + core pure helpers + shared build script)
  cp --no-preserve=mode ${./package.json} $out/package.json
  cp -r --no-preserve=mode ${./lib}/. $out/lib/
  cp -r --no-preserve=mode ${./scripts}/. $out/scripts/

  # 2) bundle pi-blackhole's pure TS core into lib/core/{compile.js,recall.js}
  #    using the package's OWN build script (single source of truth); the nix
  #    build points PI_BLACKHOLE_SRC at the flake input, a plain `pnpm build`
  #    uses node_modules/pi-blackhole. pi-blackhole is a build-time devDependency
  #    — dsh never imports the pi-extension bundle at runtime.
  ( cd $out && PI_BLACKHOLE_SRC=${pibh} bash scripts/build.sh )

  # 3) node_modules shim: resolve @deepseek-ai/* against the dsh package tree
  ln -s ${dshNodeModules} $out/node_modules
''
