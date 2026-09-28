# 本地 dsh bundle 的构建骨架。
#
# ## 模型
#
# 一个 bundle 就是一个 npm 包，其 package.json 声明 `dsh.bundle.patch`。
# dsh 读 profile 的 `dsh.profile.bundles`，按顺序把每个名字解析成包目录、读出 patch、
# 叠成一棵树。解析是**两锚点**的：先 dsh 安装目录，再 profile 目录（app-boot 的
# resolveBundleDir）。所以 bundle 只要存在于 dsh 安装的 node_modules 里 —— profile
# 目录不需要 node_modules，也不需要 pnpm。
#
# ## 为什么不用上游的 buildDshBundle
#
# 它以 `buildNpmPackage` 为构造器，于是每个 bundle 都必须提供 npmDeps /
# npmConfigHook，只为走一遍 `npm install` 把源码原样放进 $out。本仓库这些插件零运行时
# 依赖（peer 全由 kernel 提供），实测 `npmDeps = null` 时 npmConfigHook 直接以
# "no dependencies were specified" 失败。所以这里自己做等价的三件事：
#
#   1. 产物布局 `$out/lib/node_modules/<name>`；
#   2. `nix-support/dsh-bundles.json` 清单 —— 由上游的 dshBundleResolver 生成并校验
#      （它要求声明的 patch 文件真实存在且路径不逃逸包根）；
#   3. 一份指向 kernel node_modules 的软链，让裸 `@deepseek-ai/*` 导入（cordis、
#      dsh-compaction-basic 等 peer）解析得到 —— 等价于上游的 linkKernelNodeModules。
#      软链而非拷贝：kernel 拥有全部 peer，同一运行时包在整棵树里只应存在一份
#      （上游注释的 "must not resolve twice"）。
{
  lib,
  stdenvNoCC,
  nodejs-slim,
  dshBundleResolver,
  kernelPatched,
}:

{
  # 包名，也是 profile.bundles 里写的名字（带 scope 时自动建层级目录）。
  name,
  version ? "0.1.0",
  # 源码目录（必须含 package.json）。
  src,
  # `cordis.patch.yml` 的内容。默认 `[]` = 不产生顶层行，只提供一个能被 preset
  # 按名引用的包（官方 dsh-tool-bash 的处境相同：包在安装里，挂载与否由 preset 决定）。
  # 必须是合法 YAML 数组 —— dsh 拒绝空文件（"must be a top-level YAML array of
  # loader patch entries"）并跳过整个 bundle，是本轮实测踩到的坑。
  patch ? "[]",
  # 该 bundle 声明的运行时依赖，会去重展平进 dsh 的 PATH。
  runtimeDeps ? [ ],
  meta,
}:

let
  kernelNodeModules = "${kernelPatched}/lib/deepseek-harness/node_modules";
in
stdenvNoCC.mkDerivation {
  pname = name;
  inherit version src;

  dontBuild = true;
  dontConfigure = true;

  nativeBuildInputs = [ nodejs-slim ];

  installPhase = ''
    runHook preInstall

    [ -d ${kernelNodeModules} ] || {
      printf 'dsh-local: kernel node_modules is missing: %s\n' ${kernelNodeModules} >&2
      exit 1
    }

    dest="$out/lib/node_modules/${name}"
    mkdir -p "$(dirname "$dest")"
    cp -r . "$dest"
    chmod -R u+w "$dest"

    # dsh.bundle.patch 声明与 patch 文件由这里注入，而不是写在源码的 package.json 里：
    # 源码包保持可独立运行（`dsh plugin add <本地目录>` 也照样能用），
    # 「打包成 bundle」是 nix 的决定。
    cat > "$dest/cordis.patch.yml" <<'YML'
    ${patch}
    YML
    ${lib.getExe nodejs-slim} -e '
      const fs = require("node:fs")
      const p = process.argv[1]
      const m = JSON.parse(fs.readFileSync(p, "utf8"))
      m.dsh = { ...(m.dsh ?? {}), bundle: { patch: "./cordis.patch.yml" } }
      fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n")
    ' "$dest/package.json"

    # 裸 @deepseek-ai/* 导入靠这份软链解析（peer 全在 kernel 里）。
    if [ ! -e "$dest/node_modules" ] && [ ! -L "$dest/node_modules" ]; then
      ln -s ${kernelNodeModules} "$dest/node_modules"
    fi

    # 包名必须与安装路径一致：Loader 按名字从安装锚点解析，不一致时下游只报
    # "cannot resolve profile bundle"，是最难查的一类退化。
    packedName=$(${lib.getExe nodejs-slim} -p \
      "JSON.parse(require('node:fs').readFileSync('$dest/package.json','utf8')).name")
    [ "$packedName" = ${lib.escapeShellArg name} ] || {
      printf 'dsh-local: expected ${name} at %s but package.json declares %s\n' \
        "$dest" "$packedName" >&2
      exit 1
    }

    mkdir -p "$out/nix-support"
    ${lib.getExe dshBundleResolver} manifest \
      "$out/nix-support/dsh-bundles.json" "$out/lib/node_modules"

    runHook postInstall
  '';

  passthru = {
    inherit runtimeDeps;
    dshBundle = true;
    dshBundleHelper = "buildDshBundle";
  };

  meta = meta // {
    platforms = lib.platforms.unix;
  };
}
