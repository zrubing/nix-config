{
  lib,
  bashInteractive,
  buildNpmPackage,
  fetchPnpmDeps,
  fetchFromGitHub,
  importPnpmLock,
  dshWorkspacePatchHook,
  nodejs,
  nodejs-slim,
  node-gyp,
  pnpmConfigHook,
  pnpm_11,
  python3,
  stdenv,
  dsh-landlock-run,
  yq-go,
  deepseek-harness-src,
}:

let
  platformKey = with stdenv.hostPlatform.node; "${platform}-${arch}";
  fetchPnpmDeps' = fetchPnpmDeps.override { yq = yq-go; };
in
buildNpmPackage (finalAttrs: {
  pname = "dsh-workspace";
  version = "0.1.3-alpha.1";

  __structuredAttrs = true;
  strictDeps = true;

  # 源码：fetchFromGitHub 拉 dsh-v0.1.3-alpha.1（其派生源带 .name，供 dsh-landlock-run 取 sourceRoot）。
  src = fetchFromGitHub {
    owner = "deepseek-ai";
    repo = "deepseek-harness";
    tag = "dsh-v${finalAttrs.version}";
    hash = "sha256-7gje0bGlfRbo6qEubnKt3z8a6UjDGNW90g7phGU+s6g=";
  };

  env.DSH_CLIENT_COMMIT_HASH = "d347e703908d0406b7a7ef80e3a0e594d86b2215";

  nodejs = nodejs-slim;
  disallowedReferences = [
    nodejs
    pnpm_11
    python3
  ];

  postPatch = ''
    # 内网免 token：受信来源（loopback / --trusted-host）跳过浏览器会话认证，
    # 保留 Host/Origin fence（DNS rebinding / 跨站仍 403）。
    patch -p1 < ${./web-auth-bypass-trusted.patch}

    substituteInPlace "packages/terminal/terminal-bash/src/config.ts" \
      --replace-fail \
      "export const DEFAULT_BASH_SHELL = '/bin/bash'" \
      "export const DEFAULT_BASH_SHELL = '${lib.getExe bashInteractive}'"

    substituteInPlace packages/client/tsdown.client.ts \
      --replace-fail \
      "return CSS_VIRTUAL_PREFIX + abs + CSS_VIRTUAL_SUFFIX" \
      "return CSS_VIRTUAL_PREFIX + relative(process.cwd(), abs) + CSS_VIRTUAL_SUFFIX" \
      --replace-fail \
      "const fileId = virtualId.slice(CSS_VIRTUAL_PREFIX.length, -CSS_VIRTUAL_SUFFIX.length)" \
      "const fileId = resolvePath(process.cwd(), virtualId.slice(CSS_VIRTUAL_PREFIX.length, -CSS_VIRTUAL_SUFFIX.length))" \
      --replace-fail \
      "Object.entries(cssExports ?? {})" \
      "Object.entries(cssExports ?? {}).sort(([a], [b]) => a.localeCompare(b))"
  ''
  + lib.optionalString (lib.versionOlder pnpm_11.version "11.7.0") ''
    # pnpm < 11.7 cannot parse file: selectors in allowBuilds.
    yq -i '
      .allowBuilds."@deepseek-ai/dsh-subprocess-local" =
        .allowBuilds."@deepseek-ai/dsh-subprocess-local@file:packages/subprocess/subprocess-local" |
      del(.allowBuilds."@deepseek-ai/dsh-subprocess-local@file:packages/subprocess/subprocess-local")
    ' pnpm-workspace.yaml
  ''
  + lib.optionalString (lib.meta.availableOn stdenv.hostPlatform dsh-landlock-run) ''
    install -Dm755 ${dsh-landlock-run}/bin/landlock-run native/landlock-run/packages/${platformKey}/bin/landlock-run
  '';

  preConfigure = "patchDshWorkspace kernel";

  pnpmDeps = importPnpmLock {
    inherit (finalAttrs) pname version;
    fetchPnpmDeps = fetchPnpmDeps';
    lockfileJson = ./pnpm-lock.json;
    targetPlatform =
      if stdenv.buildPlatform == stdenv.hostPlatform then stdenv.targetPlatform else null;
    patchedDependencySources = {
      "node-pty@1.2.0-beta.15" = "${finalAttrs.src}/patches/node-pty@1.2.0-beta.15.patch";
      "@yao-pkg/pkg@6.21.0" = "${finalAttrs.src}/patches/@yao-pkg__pkg@6.21.0.patch";
    };
  };

  nativeBuildInputs = [
    nodejs-slim.npm
    node-gyp
    pnpm_11
    python3
    dshWorkspacePatchHook
    yq-go
  ];

  npmDeps = null;
  npmInstallFlags = finalAttrs.pnpmDeps.passthru.pnpmInstallFlags;
  npmConfigHook = pnpmConfigHook;
  npmBuildScript = "build:official";

  # node-pty's postinstall can't run before deploy assembles the composition.
  preInstall = ''
    export NODE_GYP_BIN="${lib.getBin node-gyp}/bin/node-gyp"
    export PATH="${lib.getBin node-gyp}/bin:$PATH"
    export PATH="${lib.getBin nodejs-slim}/bin:$PATH"
    pnpm config set --location=project inject-workspace-packages true
    yq -i 'del(.scripts.postinstall)' packages/subprocess/subprocess-local/package.json
  '';

  installPhase = ''
    runHook preInstall

    workspaceDir="$out/lib/dsh-workspace"
    appDir="$workspaceDir/kernel"
    mkdir -p "$workspaceDir"

    cp -r apps/cli/lib apps/nix-kernel/lib
    cp -r apps/cli/config apps/nix-kernel/config
    pnpm --filter @deepseek-ai/dsh-nix-kernel deploy \
      --prod \
      --config.ignore-scripts=true \
      --config.node-linker=hoisted \
      --config.link-workspace-packages=true \
      "$appDir"

    # pnpm deploy 只按 apps/cli 的 files 打包 lib；config 不落入产物，显式复制。
    cp -r apps/cli/config "$appDir/config"

    rm -f "$appDir/node_modules/node-pty/build/"{{binding.,}Makefile,config.gypi,pty.target.mk}
    sed -i '1{/^#!/d;}' "$appDir/lib/bin.js"
    ${lib.getExe nodejs-slim} "$appDir/node_modules/@deepseek-ai/dsh-subprocess-local/scripts/ensure-spawn-helper.mjs"

    runtimeBundlesDir="$workspaceDir/runtime-bundles"
    for packageJson in packages/*/*/package.json; do
      [ -f "$packageJson" ] || continue
      bundlePatchTag=$(yq -r '.dsh.bundle.patch | tag' "$packageJson")
      case "$bundlePatchTag" in
        "!!null")
          continue
          ;;
        "!!str")
          bundlePatch=$(yq -r '.dsh.bundle.patch' "$packageJson")
          ;;
        *)
          printf 'dsh-workspace: bundle patch must be a string: %s\n' "$packageJson" >&2
          exit 1
          ;;
      esac

      packageName=$(yq -r '.name // ""' "$packageJson")
      [ -n "$packageName" ] || {
        printf 'dsh-workspace: bundle package has no name: %s\n' "$packageJson" >&2
        exit 1
      }
      [ -n "$bundlePatch" ] || {
        printf 'dsh-workspace: bundle patch is empty: %s\n' "$packageJson" >&2
        exit 1
      }

      bundleDir="$runtimeBundlesDir/$packageName"
      mkdir -p "$(dirname "$bundleDir")"
      pnpm --filter "$packageName" deploy \
        --prod \
        --config.ignore-scripts=true \
        --config.node-linker=hoisted \
        --config.link-workspace-packages=true \
        "$bundleDir"

      for artifact in package.json "$bundlePatch" lib; do
        [ -e "$bundleDir/$artifact" ] || {
          printf 'dsh-workspace: deployed bundle artifact is missing: %s\n' "$bundleDir/$artifact" >&2
          exit 1
        }
      done
    done

    # External bundles may need client packages that are build-time peers of
    # the CLI kernel without adding them to the kernel runtime closure.
    for clientPackage in ui-commands ui-slots; do
      clientPackagesDir="$workspaceDir/client-packages/@deepseek-ai/dsh-client-$clientPackage"
      mkdir -p "$clientPackagesDir"
      cp "packages/client/$clientPackage/package.json" "$clientPackagesDir/package.json"
      cp -r "packages/client/$clientPackage/lib" "$clientPackagesDir/lib"
    done

    mkdir -p "$workspaceDir/frontends/web"
    cp apps/web/package.json "$workspaceDir/frontends/web/package.json"
    cp -r apps/web/dist "$workspaceDir/frontends/web/dist"

    # fs-ext has no prebuilt binary; pnpm's deploy lifecycle does not reliably
    # allow its node-gyp build here, so deploy with ignore-scripts and compile
    # the native addon after deploy in every location pnpm placed fs-ext, using
    # the explicit NODE_GYP_BIN and the hoisted nan already present in each
    # deployed node_modules tree.
    while IFS= read -r fsExtPkg; do
      fsExtDir="$(dirname "$fsExtPkg")"
      echo "dsh-workspace: building fs-ext native addon in $fsExtDir"
      (cd "$fsExtDir" && "$NODE_GYP_BIN" configure build)
      # Keep only the runtime .node artifact; node-gyp leaves absolute build
      # metadata referencing the build-time node/python stores in the output.
      mkdir -p "$fsExtDir/build/Release"
      find "$fsExtDir/build" -mindepth 1 -maxdepth 1 ! -name Release -exec rm -rf {} +
      find "$fsExtDir/build/Release" -mindepth 1 ! -name fs_ext.node -exec rm -rf {} +
    done < <(find "$workspaceDir" -path '*/node_modules/fs-ext/package.json' -print)

    runHook postInstall
  '';

  passthru = {
    # 上游升级入口：./update.sh（解析新 tag、算 hash、重生成 pnpm-lock.json、更新 flake.lock）
    updateScript = ./update.sh;
  };

  meta = {
    description = "Built DeepSeek Harness workspace artifacts";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
})
