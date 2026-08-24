{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  unzip,
}:

let
  version = "26.7.28";

  binaries = {
    x86_64-linux = {
      artifact = "Xray-linux-64.zip";
      hash = "sha256-gZXZCfEQm489me7+QBo8RR179K9x8k04FUIPd+XdKkA=";
    };
    aarch64-linux = {
      artifact = "Xray-linux-arm64-v8a.zip";
      hash = "sha256-9WmLshito7QCLbJvr8OWAcX1O0axnrdslhYyWYWAdQE=";
    };
  };

  platform = binaries.${stdenv.hostPlatform.system}
    or (throw "Unsupported system: ${stdenv.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "xray-core-bin";
  inherit version;

  src = fetchurl {
    url = "https://github.com/XTLS/Xray-core/releases/download/v${version}/${platform.artifact}";
    hash = platform.hash;
  };

  nativeBuildInputs = [ unzip ];

  unpackPhase = ''
    runHook preUnpack

    unzip "$src"

    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 xray "$out/bin/xray"
    install -Dm644 geoip.dat geosite.dat -t "$out/share/xray/"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Xray, Penetrates Everything (prebuilt binary from upstream release)";
    homepage = "https://github.com/XTLS/Xray-core";
    license = licenses.mpl20;
    mainProgram = "xray";
    platforms = builtins.attrNames binaries;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
  };
}
