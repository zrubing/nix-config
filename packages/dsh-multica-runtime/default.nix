{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpm_10,
  pnpmConfigHook,
  nodejs,
}:

# Multica 的 DSH runtime bridge（`@multica-ai/dsh-runtime`）。
#
# 上游只提供 TypeScript 源码，构建是 `tsc -p tsconfig.build.json` 出 `dist/`。
# 这里只负责把它编译成「包目录」，bundle 布局（lib/node_modules、nix-support
# 清单、kernel peer 软链）由 modules/home/dsh 走 dshLocal.mkBundle 完成。
stdenv.mkDerivation (finalAttrs: {
  pname = "dsh-multica-runtime";
  version = "0.2.0-private.1";

  src = fetchFromGitHub {
    owner = "dsh-external";
    repo = "dsh-multica-runtime";
    rev = "571d7c036d15f58ee88c89fd80afb0a6c7f0023c";
    hash = "sha256-YzfNGQdd2Y+oInWWHo54bQIVES7IcPE+sJf7gUleJXA=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_10;
    fetcherVersion = 3;
    hash = "sha256-50rFoTDZCdXoQ3vexoaNtZeIqOJ5nmgBPOspUrP6Ius=";
  };

  nativeBuildInputs = [
    nodejs
    pnpmConfigHook
    pnpm_10
  ];

  buildPhase = ''
    runHook preBuild
    pnpm run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r dist cordis.patch.yml package.json $out/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Multica runtime bridge for DeepSeek Harness";
    homepage = "https://github.com/dsh-external/dsh-multica-runtime";
    license = licenses.unfree;
    platforms = platforms.unix;
  };
})
