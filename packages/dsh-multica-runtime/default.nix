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
  #
  # src/index.ts 建会话时从不向 DSH 的 preset registry 要组合，所以 multica 任务
  # 跑的是裸内核工具集，与 web 会话（registry 的 default preset）不同源。按
  # `@deepseek-ai/dsh-api-session-controller` 的 composeAgent 同法补齐：
  #
  # 1. 创建会话时把 registry 的 default 解析成具体 id 写进 session header ——
  #    组合是模型看得见的东西，日志必须能说明这一轮跑在哪个组合下；
  # 2. setup 里按 header 记录的 id 挂载组合（恢复会话读到的是日志里那份）；
  # 3. header 里没有 preset 的旧会话保持原组合，不被静默换掉。
  postPatch = ''
    substituteInPlace src/lifecycle.ts \
      --replace-fail 'waitForChildren(parent: Agent): Promise<boolean>' \
                     'waitForTreeWork(parent: Agent): Promise<boolean>' \
      --replace-fail 'subagents?.waitForChildren(agent as Agent) ?? false' \
                     'subagents ? (subagents.waitForTreeWork(agent as Agent) ?? false) : false' \
      --replace-fail 'await subagents?.drainDescendants([agent as Agent])' \
                     'if (subagents) await subagents.drainDescendants([agent as Agent])'

    substituteInPlace src/index.ts \
      --replace-fail "async function createOrResumeAgent(" \
        "/** The preset registry, absent when the profile mounts no roster. */
interface PresetRegistryLike {
  resolve(id?: string): Promise<{ id: string }>
  mount(agentCtx: Context, id?: string): Promise<unknown>
  presetForSession(session: Agent['session']): string | null
}

function presetRegistry(ctx: Context): PresetRegistryLike | undefined {
  return (ctx as unknown as { get(name: string): PresetRegistryLike | undefined }).get('agentPresets')
}

/** Mount the composition the session log names. A session created before the
 *  runtime recorded presets keeps its original, uncomposed toolset. */
async function mountLoggedPreset(ctx: Context, agentCtx: Context, session: Agent['session']): Promise<void> {
  const presets = presetRegistry(ctx)
  if (presets === undefined) return
  const recorded = presets.presetForSession(session)
  if (recorded === null) return
  await presets.mount(agentCtx, recorded)
}

async function createOrResumeAgent(" \
      --replace-fail "  const setup = async (agentCtx: Context): Promise<void> => {
    installModelSelection(agentCtx, selected)
    agentCtx.on('approval/request', (_request, next) => {
      if (active.cancelRequested) return Promise.resolve<ApprovalOutcome>('cancelled')
      return Promise.resolve<ApprovalOutcome>('allowed-once').catch(() => next())
    })
    for (const server of active.command.mcp_servers) {
      await agentCtx.plugin(McpClient, mcpConfig(server, active.command.cwd))
    }
  }" \
        "  const setup = async (agentCtx: Context, agent: Agent): Promise<void> => {
    installModelSelection(agentCtx, selected)
    agentCtx.on('approval/request', (_request, next) => {
      if (active.cancelRequested) return Promise.resolve<ApprovalOutcome>('cancelled')
      return Promise.resolve<ApprovalOutcome>('allowed-once').catch(() => next())
    })
    for (const server of active.command.mcp_servers) {
      await agentCtx.plugin(McpClient, mcpConfig(server, active.command.cwd))
    }
    await mountLoggedPreset(ctx, agentCtx, agent.session)
  }" \
      --replace-fail "  const options = { provider: selection.provider, model: selection.model }
  if (active.command.resume_session_id === undefined) {" \
        "  const options = { provider: selection.provider, model: selection.model }
  if (active.command.resume_session_id === undefined) {
    const presets = presetRegistry(ctx)
    const agentPreset = presets === undefined ? undefined : (await presets.resolve(undefined)).id" \
      --replace-fail '      meta: { cwd: active.command.cwd },' \
                     '      meta: agentPreset === undefined ? { cwd: active.command.cwd } : { cwd: active.command.cwd, agentPreset },'
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
