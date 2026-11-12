{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  unzip,
}:

let
  # 上游撤版会连 release 资产一起删（v26.10.29 因默认启用 MPTCP 被撤，现为 404），
  # 已 pin 的版本不能保证可重建；升级前确认 zip 返回 206：
  #   curl -sS -o /dev/null -w '%{http_code}\n' -r 0-1023 \
  #     https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-64.zip
  version = "26.11.9";

  binaries = {
    x86_64-linux = {
      artifact = "Xray-linux-64.zip";
      hash = "sha256-tlH34dmWbuLBse4b+LUscncYJNMGXc6Wu8i8wZ7ZX4I=";
    };
    aarch64-linux = {
      artifact = "Xray-linux-arm64-v8a.zip";
      hash = "sha256-ZO1oWJgqf164XYi4EQiQY71PF1YfTI9E4PHcjm9kML4=";
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
