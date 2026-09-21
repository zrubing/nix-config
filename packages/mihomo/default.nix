{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  gzip,
}:

let
  version = "1.19.31";

  binaries = {
    x86_64-linux = {
      artifact = "mihomo-linux-amd64-v${version}.gz";
      hash = "sha256-1edLvdvf/0mhrvd3W/WRHaWfDXGW7VCaCskUs2U91fE=";
    };
    aarch64-linux = {
      artifact = "mihomo-linux-arm64-v${version}.gz";
      hash = "sha256-ng8Rr784QmuL2I/cWUZ4+BYcV+zLTht3rLErSTkE8dQ=";
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
