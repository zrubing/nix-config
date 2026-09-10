{
  lib,
  stdenvNoCC,
  fetchurl,
  fetchzip,
  makeBinaryWrapper,
  nodejs_24,
  coreutils,
}:

let
  pname = "codebuddy-code";
  version = "2.148.0";

  nodejs = nodejs_24;

  # npm 发布包已经是完整 bundle（dist/ 三个变体 + vendor/ 各平台 ripgrep），
  # dependencies 为空、无构建步骤，直接解包 + 包装入口。
  #
  # 唯一的可选依赖是 @lydell/node-pty：bundle 里 `await import("@lydell/node-pty")`
  # 拿真 PTY，失败时 try/catch 返回 null（终端相关能力降级）。按平台补上，
  # 与 npm 装法（optionalDependencies）行为一致。node-pty 自带各平台预编译
  # pty.node，不触发本地编译。
  nodePtyVersion = "1.2.0-beta.14";
  nodePtyPlatforms = {
    x86_64-linux = {
      tarball = "node-pty-linux-x64";
      hash = "sha256-JGGpyvwjVDfmcLQTSRPUndN62rqOvJk1RoMC3mQg4H0=";
    };
    aarch64-linux = {
      tarball = "node-pty-linux-arm64";
      hash = "sha256-7ahwTMVW/OHJ3OA5g3GLQU/RCw/QVs2xXHRxdoky9ig=";
    };
  };
  nodePty = nodePtyPlatforms.${stdenvNoCC.hostPlatform.system}
    or (throw "codebuddy-code: ${stdenvNoCC.hostPlatform.system} 没有 @lydell/node-pty 预编译包");
in
stdenvNoCC.mkDerivation (finalAttrs: {
  inherit pname version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@tencent-ai/codebuddy-code/-/codebuddy-code-${version}.tgz";
    hash = "sha256-irCwV4pVrymtbUVU767SWkAgcS6/+Z01oBF5AD6Ua5U=";
  };

  nodePtySrc = fetchzip {
    url = "https://registry.npmjs.org/@lydell/node-pty/-/node-pty-${nodePtyVersion}.tgz";
    hash = "sha256-5gJi7s9zmSaDD4qY6SSjdTOZbsf/ZxUqFW/MA1CikrE=";
  };

  nodePtyPlatformSrc = fetchzip {
    url = "https://registry.npmjs.org/@lydell/${nodePty.tarball}/-/${nodePty.tarball}-${nodePtyVersion}.tgz";
    hash = nodePty.hash;
  };

  sourceRoot = "package";

  nativeBuildInputs = [ makeBinaryWrapper ];

  dontBuild = true;

  # fixupPhase 的 patchShebangs 解析不了 bin/ 下这几条 shebang：`#!/usr/bin/env node`
  # 里的 node 找不到（PATH 里没有），`env -S node --flag` 更是被抹成空命令。入口本身
  # 走 wrapper 不受影响，这里统一补成 store 路径，脚本直接执行也能用、语义与上游一致
  # （lowmem 的 V8 flag 必须保留 env -S，Linux shebang 只透传一个参数）。
  postFixup = ''
    sed -i "1c #!${lib.getExe nodejs}" \
      $out/lib/codebuddy-code/bin/codebuddy \
      $out/lib/codebuddy-code/bin/cbc-prewarm
    sed -i "1c #!${coreutils}/bin/env -S ${lib.getExe nodejs} --optimize-for-size --max-semi-space-size=2" \
      $out/lib/codebuddy-code/bin/codebuddy-lowmem
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/codebuddy-code
    cp -r . $out/lib/codebuddy-code/

    # dist/ 里的 import("@lydell/node-pty") 从 bundle 目录逐级向上解析，
    # 所以 node_modules 必须落在 bundle 根下。
    mkdir -p $out/lib/codebuddy-code/node_modules/@lydell
    cp -r ${finalAttrs.nodePtySrc} $out/lib/codebuddy-code/node_modules/@lydell/node-pty
    cp -r ${finalAttrs.nodePtyPlatformSrc} $out/lib/codebuddy-code/node_modules/@lydell/${nodePty.tarball}

    # 入口统一用 node 跑脚本。
    # DISABLE_AUTOUPDATER：npm 装法下自更新会 `npm install -g` 覆盖安装目录，
    # nix store 只读，必须关掉（codebuddy 读 BooleanUtils.isTruthy 判定）。
    mkdir -p $out/bin
    makeWrapper ${lib.getExe nodejs} $out/bin/codebuddy \
      --add-flags $out/lib/codebuddy-code/bin/codebuddy \
      --prefix PATH : ${lib.makeBinPath [ nodejs ]} \
      --set DISABLE_AUTOUPDATER 1

    ln -s codebuddy $out/bin/cbc
    ln -s codebuddy $out/bin/codebuddy-code

    # bin/codebuddy-lowmem 的 shebang 是 `env -S node --optimize-for-size
    # --max-semi-space-size=2`（低内存模式），wrapper 里显式带上这两个 V8 flag。
    makeWrapper ${lib.getExe nodejs} $out/bin/codebuddy-lowmem \
      --add-flags "--optimize-for-size --max-semi-space-size=2 $out/lib/codebuddy-code/bin/codebuddy-lowmem" \
      --prefix PATH : ${lib.makeBinPath [ nodejs ]} \
      --set DISABLE_AUTOUPDATER 1

    # 纯 Node 脚本（只用内置模块），不加载主 bundle。
    makeWrapper ${lib.getExe nodejs} $out/bin/cbc-prewarm \
      --add-flags $out/lib/codebuddy-code/bin/cbc-prewarm \
      --prefix PATH : ${lib.makeBinPath [ nodejs ]}

    runHook postInstall
  '';

  meta = {
    description = "CodeBuddy Code —— 腾讯 AI 编程助手命令行";
    homepage = "https://cnb.cool/codebuddy/codebuddy-code";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ ];
    mainProgram = "codebuddy";
    platforms = builtins.attrNames nodePtyPlatforms;
  };
})
