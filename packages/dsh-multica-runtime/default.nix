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

  # 上游 lifecycle.ts 的两个调用点只对 `subagents` 本体做了可选链，方法调用没
  # 兜住。该文件的注释明确写着「subagents 在 profile 没挂载时为 absent」，而原生
  # `dsh --profile multica --stdio` 正是没挂载的情形：此时
  # `subagents?.waitForChildren(agent)` 会先得到 undefined 再被调用，抛
  # "subagents?.waitForChildren is not a function"，导致 turn 正常结束、评论已经
  # 发出去，任务却被判 failed（UI 显示 Agent execution error）。
  # 按注释表达的契约改成「有服务才调用」，不改行为。
  postPatch = ''
    substituteInPlace src/lifecycle.ts \
      --replace-fail 'subagents?.waitForChildren(agent as Agent) ?? false' \
                     'subagents ? subagents.waitForChildren(agent as Agent) : false' \
      --replace-fail 'await subagents?.drainDescendants([agent as Agent])' \
                     'if (subagents) await subagents.drainDescendants([agent as Agent])'
  '';

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
