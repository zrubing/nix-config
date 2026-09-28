# dsh-tui bundle —— 从 ccch1mneyyy/dsh-TUI 源码构建（不再是 npm tarball）。
#
# 出处：移植自 Moraxyc/deepseek-harness.nix 的 pkgs/bundles/tui/package.nix
# （本仓库 pkgs/dsh-moraxyc 的共同上游）。此前 modules/home/dsh 直接从 npm 拉
# @deepseek-harness-tui/dsh-tui 的 tgz，再手填两个 SRI 哈希、无 lockfile——
# 依赖一发新版就崩。这里改用上游的 buildDshBundle 协议，源码锁在 GitHub tag，
# src/pnpmDeps 两个哈希都可复现，nix-update-script 可自动 bump。
#
# 与上游的两处差异（上游 nixpkgs 较新）：
#   1. 上游用 copyTree.followLinks 展开 workspace 符号链接；我们的 nixpkgs 没有
#      copyTree（实测 p ? copyTree == false），换成语义等价的 cp -rL。
#   2. 上游在 lib/mk-dsh-bundle.nix 里给所有 bundle 注入
#      PNPM_CONFIG_MANAGE_PACKAGE_MANAGER_VERSIONS=false；我们本地那份没有这个
#      注入，所以在 env 里自己带上——dsh-TUI 的 package.json 声明了 packageManager
#      字段，不禁用的话 pnpm 会去下载它指定的 pnpm 版本。
#
# 三个 submodule（dsh-ecosystem-spec / vendor/dsh-std / dsh-auth）都是公开仓库，
# fetchSubmodules 可解析；源码 tarball 没有 .git，所以 postPatch 把两个校验脚本里
# 的 git 调用替换成等价实现（上游做法，照抄）。
{
  lib,
  fetchFromGitHub,
  fetchPnpmDeps,
  buildDshBundle,
  dsh-kernel,
  pnpmConfigHook,
  pnpm_11,
  nix-update-script,
}:

let
  # copyTree.followLinks { src, dest } 的本地等价物：把 src 整棵树解引用后放到 dest
  # （dest 的父目录必须已存在）。
  copyFollowLinks =
    src: dest:
    ''
      rm -rf ${dest}
      cp -rL --no-preserve=mode ${src} ${dest}
    '';
in
buildDshBundle (finalAttrs: {
  pname = "dsh-tui";
  version = "0.11.1";

  src = fetchFromGitHub {
    owner = "ccch1mneyyy";
    repo = "dsh-TUI";
    rev = "refs/tags/v${finalAttrs.version}";
    fetchSubmodules = true;
    hash = "sha256-ZQ03CKIPdDclQg/P7ZXcBb1OLwZn47xu4B/BRwx/swg=";
  };

  # 侧问（/btw）探针的 render-settle 补丁：单次 sleep 会和渲染赛跑。
  patches = [ ./btw-side-question-settle.patch ];

  postPatch = ''
    chmod -R u+w vendor/dsh-std dsh-ecosystem-spec dsh-auth

    # fetchFromGitHub 给的是 tarball，没有 git index，而 verify:i18n 只是要
    # 源文件清单做静态扫描。
    substituteInPlace scripts/verify-i18n.ts \
      --replace-fail \
        "execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', 'src', 'scripts'], { encoding: 'utf8' })" \
        "execFileSync('find', ['src', 'scripts', '-type', 'f', '-print0'], { encoding: 'utf8' })"

    # submodule 在 Nix 沙箱里没有 .git 目录。
    substituteInPlace scripts/verify-protocol-single-source.ts \
      --replace-fail \
        "const head = execFileSync('git', ['-C', specGitDir, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()" \
        "const { ECOSYSTEM_SPEC_REVISION: head } = await import('../src/adapter/standard/registry.js')" \
      --replace-fail \
        "const status = execFileSync('git', ['-C', specGitDir, 'status', '--short'], { encoding: 'utf8' }).trim()" \
        "const status = \"\""

  '';

  # 静态 import 会在校验脚本设置 process-local 语言之前就初始化 i18n；在无 locale
  # 的 Nix 沙箱里把构建期 UI 断言钉到 en。
  env = {
    DSH_TUI_LANG = "en";
    PNPM_CONFIG_MANAGE_PACKAGE_MANAGER_VERSIONS = "false";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_11;
    fetcherVersion = 4;
    postPatch = finalAttrs.postPatch;
    # 两个 submodule 各自又是一个 pnpm 工程，主 install 不会覆盖它们。
    prePnpmInstall = ''
      pnpm --dir vendor/dsh-std install \
        --ignore-scripts \
        --frozen-lockfile
      pnpm --dir dsh-auth install \
        --ignore-scripts \
        --frozen-lockfile
    '';
    hash = "sha256-cN6c07aWC6VRMHkWL1LtW6rJXejTFYncq6jMwoJUWdM=";
  };

  nativeBuildInputs = [ pnpm_11 ];
  disallowedReferences = [ pnpm_11 ];
  linkKernelNodeModules = dsh-kernel;
  # dsh-tui 编译时链接 React 19，而 dsh-kernel 带的是 React 18；
  # supports-hyperlinks@3.2.0 需要 supports-color@7 的函数导出，kernel 带的是 9.x。
  linkKernelNodeModulesKeep = [
    "ansi-styles"
    "react"
    "supports-color"
  ];

  npmDeps = null;
  npmConfigHook = pnpmConfigHook;
  npmBuildScript = "build";

  installPhase = ''
    runHook preInstall

    appDir="$out/lib/node_modules/@deepseek-harness-tui/dsh-tui"
    mkdir -p "$appDir"

    cp -r package.json cordis.patch.yml cordis.yml dsh-ecosystem-spec presets lib "$appDir/"
    # bundle 私有依赖（auto-bind、dsh-working-activity 等）不在 kernel 里；
    # linkKernelNodeModules 会把 kernel 的 peer 合并进这棵树。
    cp -r node_modules "$appDir/node_modules"

    # workspace 链接指向 vendor/dsh-std，而它没被安装。
    ${copyFollowLinks "node_modules/@dsh-std" "$appDir/node_modules/@dsh-std"}

    # dsh-auth 在源码 tarball 里是 workspace 链接，必须拷成实体，否则留下悬空链接。
    ${copyFollowLinks "node_modules/@deepseek-harness-tui/dsh-auth" "$appDir/node_modules/@deepseek-harness-tui/dsh-auth"}

    runHook postInstall
  '';

  passthru = {
    inherit (finalAttrs) pnpmDeps;
    requiresTui = true;
    requiresTty = true;

    updateScript = nix-update-script {
      extraArgs = [
        "--flake"
        "--override-filename=pkgs/bundles/tui/package.nix"
      ];
    };
  };

  meta = {
    description = "Interactive terminal interface for dsh";
    descriptions.zh-CN = "dsh 的交互式终端界面";
    homepage = "https://github.com/ccch1mneyyy/dsh-TUI";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
})
