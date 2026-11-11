{
  lib,
  writeShellApplication,
  nodejs,
  dshHostPackage,
  dshTuiRemoteTree,
  dshVersion,
}:

# Multica 的 DSH runtime 桥：把 multica 的 stdio JSONL 协议翻译成对常驻
# `dsh-web` host 的 remote RPC。设计说明见 ./bridge.mjs。
#
# 依赖两个由 dsh 模块注入的路径：
#   dshHostPackage    —— 让 dsh-tui-remote 的 findHostDsh 找到「装着 host」的包目录
#   dshTuiRemoteTree  —— 复用它的 remote 客户端模块，保证协议半边与 host 同源
writeShellApplication {
  name = "dsh-multica-bridge";

  runtimeInputs = [ nodejs ];

  text = ''
    export DSH_HOST_PACKAGE=${dshHostPackage}
    export DSH_TUI_REMOTE_TREE=${dshTuiRemoteTree}
    # daemon 用 `--version` 做 agent 版本探测；报 host 的 dsh 版本，
    # 否则 multica 会按「未知版本」跳过或拒绝注册。
    export DSH_BRIDGE_DSH_VERSION=${dshVersion}
    export DSH_BRIDGE_VERSION=0.1.0
    export PATH="$DSH_HOST_PACKAGE:$PATH"
    exec ${lib.getExe nodejs} ${./bridge.mjs} "$@"
  '';

  meta = with lib; {
    description = "Multica runtime bridge that attaches tasks to the running dsh web host";
    platforms = platforms.unix;
    mainProgram = "dsh-multica-bridge";
  };
}
