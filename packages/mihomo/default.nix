{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  gzip,
}:

let
  version = "1.19.25";

  binaries = {
    x86_64-linux = {
      artifact = "mihomo-linux-amd64-v${version}.gz";
      hash = "sha256-3jcdrJ+XrMDB0CDR+/+atyrXE7vLbftRvOA4pealQw8=";
    };
    aarch64-linux = {
      artifact = "mihomo-linux-arm64-v${version}.gz";
      hash = "sha256-DS8ZxL8wEh/v9MpRoaXd14N+4fn6r5MMqDUzvKUeizQ=";
    };
  };

  platform = binaries.${stdenv.hostPlatform.system}
    or (throw "Unsupported system: ${stdenv.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "mihomo";
  inherit version;

  src = fetchurl {
    url = "https://github.com/MetaCubeX/mihomo/releases/download/v${version}/${platform.artifact}";
    hash = platform.hash;
  };

  nativeBuildInputs = [ gzip ];

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    gzip -dc "$src" > mihomo
    install -Dm755 mihomo "$out/bin/mihomo"

    runHook postInstall
  '';

  meta = with lib; {
    description = "A rule-based tunnel in Go";
    homepage = "https://github.com/MetaCubeX/mihomo";
    license = licenses.gpl3Only;
    mainProgram = "mihomo";
    platforms = builtins.attrNames binaries;
  };
}
