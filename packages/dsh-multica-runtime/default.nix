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

  # src/lifecycle.ts 是本包唯一按名字调 DSH 服务方法的地方，两处都要对齐到
  # DSH 0.2.2-rc.3 的实际 API：
  #
  # 1. 子 agent 汇合接口改名。rc.3 把 `waitForChildren(parent)` 换成
  #    `waitForTreeWork(root)`，语义未变（join 进展中的子树工作，返回是否 join 过，
  #    见 dsh-subagent/lib/index.js 的两处 JSDoc）。上游这份 runtime 写于 rc.2，
  #    `engines.dsh` 声明 `>=0.2.1-rc.2 <0.3.0`，所以 rc.3 能装上、构建也能过，
  #    只在运行期抛 "subagents.waitForChildren is not a function"：turn 已经正常
  #    结束、评论已经发出去，multica 却把整个任务判 failed，UI 显示
  #    Agent execution error。DSH 再改名时这里跟着改，漏改的表现仍是这条运行期报错。
  # 2. `subagents` 缺席时上游只对服务本体做了可选链，方法调用没兜住（该文件注释
  #    写明「subagents 在 profile 没挂载时为 absent」）。按注释表达的契约改成
  #    「有服务才调用」，不改行为。
  postPatch = ''
    substituteInPlace src/lifecycle.ts \
      --replace-fail 'waitForChildren(parent: Agent): Promise<boolean>' \
                     'waitForTreeWork(parent: Agent): Promise<boolean>' \
      --replace-fail 'subagents?.waitForChildren(agent as Agent) ?? false' \
                     'subagents ? (subagents.waitForTreeWork(agent as Agent) ?? false) : false' \
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
