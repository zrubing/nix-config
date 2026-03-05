{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
  version = "2.1.14";

  binaries = {
    x86_64-linux = {
      artifact = "zli-linux-amd64";
      hash = "sha256-1Bc3yoG713F/wFcOWlvxVUqXYKHTc6aozGu2GOUuZ48=";
    };
    aarch64-linux = {
      artifact = "zli-linux-arm64";
      hash = "sha256-lSS44aTcGzQoFg8NLk/K9XsX7Udyl7MqHE9La/vQjwg=";
    };
    x86_64-darwin = {
      artifact = "zli-darwin-amd64";
      hash = "sha256-vZjQfTGnoGHlZMGAFVhWR7ZhhwG9OY7CUGdPfnk5TXw=";
    };
    aarch64-darwin = {
      artifact = "zli-darwin-arm64";
      hash = "sha256-yebhvlOZI+EMle3D86ocIWhSGpB//tCKxxp6DcsLfhc=";
    };
  };

  platform = binaries.${stdenvNoCC.hostPlatform.system}
    or (throw "Unsupported system: ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "zli";
  inherit version;

  src = fetchurl {
    url = "https://github.com/project-zot/zot/releases/download/v${version}/${platform.artifact}";
    hash = platform.hash;
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 "$src" "$out/bin/zli"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Command-line client for zot registry";
    homepage = "https://github.com/project-zot/zot";
    license = licenses.asl20;
    mainProgram = "zli";
    platforms = builtins.attrNames binaries;
  };
}
