{
  lib,
  pkgsStatic,
  dsh-workspace,
}:
let
  inherit (pkgsStatic) stdenv; # follow upstream
  inherit (stdenv.hostPlatform.node) arch platform;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "dsh-landlock-run";
  # 与上游 native/system/packages/entry 同版本：landlock 启动器与 flock 插件同属
  # @deepseek-ai/node-addon-system 家族（flock 由上游 build:native-system 编译，
  # 这里只负责 npm 发布版才预置的静态 landlock-run 启动器）。
  version = "0.1.2";

  inherit (dsh-workspace) src;

  sourceRoot = "${finalAttrs.src.name}/native/system";

  buildPhase = ''
    runHook preBuild

    $CC -std=c11 -Os -Wall -Wextra -Werror -static -s \
      packages/entry/src/main.c \
      -o landlock-run

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 landlock-run "$out/bin/landlock-run"
    install -Dm644 packages/entry/src/main.c "$out/share/dsh-landlock-run/main.c"
    install -Dm644 packages/${platform}-${arch}/prebuilds.json "$out/share/dsh-landlock-run/prebuilds.json"

    runHook postInstall
  '';

  meta = {
    description = "Static Landlock self-restrict-then-exec launcher for dsh";
    homepage = "https://github.com/deepseek-ai/deepseek-harness/tree/blob/native/system";
    license = lib.licenses.bsd3;
    mainProgram = "landlock-run";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
})
