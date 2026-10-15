{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  gzip,
}:

let
  version = "1.19.32";

  binaries = {
    x86_64-linux = {
      artifact = "mihomo-linux-amd64-v${version}.gz";
      hash = "sha256-hFEQCDbJ7aGUMxwrq/rUkLL68wzrwaBLDnb9isLTXRA=";
    };
    aarch64-linux = {
      artifact = "mihomo-linux-arm64-v${version}.gz";
      hash = "sha256-ndhi4otG/313XxaczuvCjezKoKnoBCN9QhzSVx4Mq6A=";
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
