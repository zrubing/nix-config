{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
}:

let
  version = "0.3.38";

  binaries = {
    x86_64-linux = {
      artifact = "multica-cli-${version}-linux-amd64.tar.gz";
      hash = "sha256-bgi0rsE3QYOMQNkTGnBC1Pz4Mbp6IsZ0lfNXomJGsGA=";
    };
    aarch64-linux = {
      artifact = "multica-cli-${version}-linux-arm64.tar.gz";
      hash = "sha256-2gnvRnsak4Bcw+F4kWsAweBPJsKUoi1BxpIbdhiz0Ig=";
    };
    x86_64-darwin = {
      artifact = "multica-cli-${version}-darwin-amd64.tar.gz";
      hash = "sha256-GvYJxz66VT6HyrS2l2/fmss1DCe0boG8dGzmbEl63Qw=";
    };
    aarch64-darwin = {
      artifact = "multica-cli-${version}-darwin-arm64.tar.gz";
      hash = "sha256-jfAoTB7Y6kV4CNWdEFL01OFNaL/aTZ9VJJDuc9xRwTY=";
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
