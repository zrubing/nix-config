{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
}:

let
  version = "0.3.11";

  binaries = {
    x86_64-linux = {
      artifact = "multica-cli-${version}-linux-amd64.tar.gz";
      hash = "sha256-xi5sI4xBZVNP5DkDSkey0qKXbr/4eaOr1o5cqiVCeWY=";
    };
    aarch64-linux = {
      artifact = "multica-cli-${version}-linux-arm64.tar.gz";
      hash = "sha256-FaL2HGVEOrMkcQ8mNSq3fbe9i1PmLiMKuAc7o3vgc+Y=";
    };
    x86_64-darwin = {
      artifact = "multica-cli-${version}-darwin-amd64.tar.gz";
      hash = "sha256-ePUpA3YIJbDURUgIFQTOSjwg6uUZwjIBYV67G0dOdbg=";
    };
    aarch64-darwin = {
      artifact = "multica-cli-${version}-darwin-arm64.tar.gz";
      hash = "sha256-AK+kai39+7ZJjxVwjd31clsCOfARG7QGosf3LBQvxYQ=";
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
