{
  lib,
  stdenv,
  fetchurl,
}:

# Lark/飞书官方 CLI（larksuite/cli）。上游只发预编译的静态 Go 二进制
# （linux-amd64 / linux-arm64 tarball），nixpkgs 里没有对应包，这里直接
# 取 release tarball 摆进 bin，不走 patchelf —— 二进制本身是静态链接。
#
# 运行期不依赖包内资源：命令目录与 agent skills 都编进二进制，
# 用 `lark-cli skills list` / `lark-cli schema ...` 现取。
stdenv.mkDerivation (finalAttrs: {
  pname = "lark-cli";
  version = "1.0.100";

  src = fetchurl {
    url = "https://github.com/larksuite/cli/releases/download/v${finalAttrs.version}/lark-cli-${finalAttrs.version}-linux-amd64.tar.gz";
    hash = "sha256-zXNj9zHJ5d0r7NkJg3kiz/6oqtIp1YGoTrE8aqDOaAg=";
  };

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    install -Dm755 lark-cli $out/bin/lark-cli
    runHook postInstall
  '';

  meta = {
    description = "Official Lark/Feishu CLI (built for humans and AI agents)";
    homepage = "https://github.com/larksuite/cli";
    license = lib.licenses.mit;
    mainProgram = "lark-cli";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
