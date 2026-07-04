{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
}:

let
  version = "0.3.37";

  binaries = {
    x86_64-linux = {
      artifact = "multica-cli-${version}-linux-amd64.tar.gz";
      hash = "sha256-OR1OhBccR7kEBnwpP3FuK2SGP9hCWYCVgX5shu7vD9E=";
    };
    aarch64-linux = {
      artifact = "multica-cli-${version}-linux-arm64.tar.gz";
      hash = "sha256-9jAmigNlfqT+qRP5ewg3JttkJTcbDM03hw1p6m5UE8I=";
    };
    x86_64-darwin = {
      artifact = "multica-cli-${version}-darwin-amd64.tar.gz";
      hash = "sha256-tsJQu1wcSbz1J0AbbXM1K2NArvLKef1Vh2ZlnccKcJc=";
    };
    aarch64-darwin = {
      artifact = "multica-cli-${version}-darwin-arm64.tar.gz";
      hash = "sha256-99ElFtHB2YgYGZMOzbZXofrutmhSai2jQWOrB+URuEk=";
    };
  };

  platform = binaries.${stdenv.hostPlatform.system}
    or (throw "Unsupported system: ${stdenv.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "multica";
  inherit version;

  src = fetchurl {
    url = "https://github.com/multica-ai/multica/releases/download/v${version}/${platform.artifact}";
    hash = platform.hash;
  };

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall

    install -Dm755 multica "$out/bin/multica"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Multica CLI — local agent runtime and management tool";
    homepage = "https://github.com/multica-ai/multica";
    license = licenses.unfree;
    mainProgram = "multica";
    platforms = builtins.attrNames binaries;
  };
}
