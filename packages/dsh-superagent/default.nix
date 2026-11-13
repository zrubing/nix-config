{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpm_11,
  pnpmConfigHook,
  nodejs,
}:

# dsh-superagent：面向**单个** GitHub 仓库的主动式 coding agent，以 DSH bundle 形式
# 发布（上游 package.json 是 private:true，npm 上没有发布包，只能从源码构）。
#
# 产物是「一个包目录」，bundle 布局（lib/node_modules、nix-support 清单、bundle 层
# 的 patch 注入）由 modules/home/dsh 走 dshLocal.mkBundle 完成 —— 与
# packages/dsh-multica-runtime 同一分工。
#
# ## 为什么要自带 node_modules
#
# 它与 dsh-local 里那些零运行期依赖的本地插件不同：package.json 把
# proper-lockfile 与 zod 声明成真实依赖（stateDir 的进程锁与配置校验都靠它们），
# installation 里只有 zod。所以构建结束后 `pnpm prune --prod` 保留生产依赖
# （实测只剩 proper-lockfile / zod，共 6MB），peer 全被 prune 掉。
#
# @deepseek-ai/* 仍必须来自 installation：同一运行时包在整棵树里只应存在一份
# （上游 share-installation-packages.mjs 的同一意图）。这条软链由 mkBundle 的
# shareInstallationScope 落下，本文件不碰 —— 包目录在这里保持「可独立运行」。
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "dsh-superagent";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "deepseek-ai";
    repo = "dsh-superagent-prototype";
    # 上游只有一个提交（2026-10-31）。研究原型，没有 tag 可跟，只能钉 rev。
    rev = "8c32a9dc5d72c033816c6a8110b37f40cf94fba4";
    hash = "sha256-MMC8oFIT4jwEXgZdU+d9bYooAAEWngdMUySsjJsK5DY=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_11;
    # tui/multica 两个 bundle 的先例：pnpm 11 用 fetcherVersion 4。
    fetcherVersion = 4;
    hash = "sha256-hReVwxtdn71JFUWIZ7pVye8ggP/eIvWcP10Od1OIdL0=";
  };

  nativeBuildInputs = [
    nodejs
    pnpmConfigHook
    pnpm_11
  ];

  # package.json 的 packageManager 是 pnpm@11.7.0，沙箱里那份是 11.27；
  # corepack 在离线环境里会尝试下载指定版本，直接关掉。
  env.PNPM_CONFIG_MANAGE_PACKAGE_MANAGER_VERSIONS = "false";

  buildPhase = ''
    runHook preBuild
    # tsdown：宿主入口出 ESM（lib/index.js 等），客户端入口出 CJS（lib/client.js）。
    pnpm run build
    # devDependencies 不进产物（typescript/tsdown/vitest 都不小）。
    pnpm prune --prod
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    # prompts/ 与 skills/ 是运行期读的（package.json 的 files 里有它们），
    # lib/ 是构建产物，locale/ 是面板文案，cordis.patch.yml 是 bundle 层声明。
    cp -r package.json cordis.patch.yml lib locale prompts skills node_modules $out/

    runHook postInstall
  '';

  meta = with lib; {
    description = "Proactive coding agent for one GitHub repository, as a DeepSeek Harness bundle";
    homepage = "https://github.com/deepseek-ai/dsh-superagent-prototype";
    license = licenses.mit;
    platforms = platforms.unix;
  };
})
