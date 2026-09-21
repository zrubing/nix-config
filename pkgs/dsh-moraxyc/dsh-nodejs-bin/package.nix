{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

# 官方 Node.js 预编译二进制，仅作为 dsh 的运行时。
#
# 为什么不用 nixpkgs 的 nodejs/nodejs-slim：dsh 0.1.6-alpha.2 的 boot 阶段会调用
# node-addon-require-builtin，其原生 loader（node-addon-native-custom-loader 0.1.6）
# 靠扫描 Node 可执行文件的机器码定位 internal getter。nixpkgs 构建的 Node 24.19.0
# （release-26.05 / unstable、nodejs_22 实测皆然）识别失败，报
# "Unsupported/no-getter (x64 sysv getter is not a recognized this->field accessor)"，
# dsh 启动即退出（alpha.1 不走这条 boot 路径，所以此前正常）。官方预编译 Node
# 同一版本可被正常识别，故运行时换用它；构建期仍用 nixpkgs Node。
#
# 只装 bin/node：官方 tarball 里的 npm/头文件对运行 dsh 无用，ICU 数据内嵌，
# 已实测单独复制后 Intl 与 addon 均正常。

let
  version = "24.19.0";
  platforms = {
    x86_64-linux = {
      tarball = "linux-x64";
      hash = "sha256-FLNC5xIE+BG95hU76OBLYq72PCNv75K1X5yDFUtAlkc=";
    };
    aarch64-linux = {
      tarball = "linux-arm64";
      hash = "sha256-AUQ8Hhop5THMrVpG/vpt9JDSGJxJ95VZBK7Nuw/ob9w=";
    };
  };
  platform =
    platforms.${stdenv.hostPlatform.system}
      or (throw "dsh-nodejs-bin: unsupported system ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "dsh-nodejs-bin";
  inherit version;

  src = fetchurl {
    url = "https://nodejs.org/dist/v${version}/node-v${version}-${platform.tarball}.tar.xz";
    inherit (platform) hash;
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/node "$out/bin/node"
    runHook postInstall
  '';

  meta = {
    description = "Official Node.js binary used as the dsh runtime";
    homepage = "https://nodejs.org";
    license = lib.licenses.mit;
    mainProgram = "node";
    platforms = builtins.attrNames platforms;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
