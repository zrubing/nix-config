{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
}:

let
  version = "0.3.13";

  binaries = {
    x86_64-linux = {
      artifact = "multica-cli-${version}-linux-amd64.tar.gz";
      hash = "sha256-unOVPcFERfemTytcAgfAxsbaMzRrFKySALPaQu5nAuU=";
    };
    aarch64-linux = {
      artifact = "multica-cli-${version}-linux-arm64.tar.gz";
      hash = "sha256-8pAMH/IYKj4h9GEoawXpf9qm5eBV+WSUNTC9e5ehC6Q=";
    };
    x86_64-darwin = {
      artifact = "multica-cli-${version}-darwin-amd64.tar.gz";
      hash = "sha256-UjThw6cfF6AanjMbZkBmTjkSFgbrk9EinxnrfuaEbKg=";
    };
    aarch64-darwin = {
      artifact = "multica-cli-${version}-darwin-arm64.tar.gz";
      hash = "sha256-TWgJuVgzCxPXgfyQjVvzlnOiLFzbHfN4CpT6YIN56us=";
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
