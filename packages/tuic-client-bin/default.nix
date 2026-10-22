{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
  version = "2.0.0-dev7";

  binaries = {
    x86_64-linux = {
      artifact = "tuic-client-x86_64-linux-musl";
      hash = "sha256-axHbOPTpc39lpPdwRPp+SoDX3r/U3B9tMkZVmMhGO3E=";
    };
    aarch64-linux = {
      artifact = "tuic-client-aarch64-linux-musl";
      hash = "";
    };
  };

  platform = binaries.${stdenvNoCC.hostPlatform.system}
    or (throw "Unsupported system: ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "tuic-client";
  inherit version;

  src = fetchurl {
    url = "https://github.com/Itsusinn/tuic/releases/download/v${version}/${platform.artifact}";
    hash = platform.hash;
  };

  # 静态 pie musl 产物：没有任何动态依赖，patchELF / strip 只会把它改坏。
  dontUnpack = true;
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 "$src" "$out/bin/tuic-client"

    runHook postInstall
  '';

  meta = with lib; {
    description = "TUIC v2 client (Itsusinn fork) — SOCKS5 front for a TUIC relay";
    homepage = "https://github.com/Itsusinn/tuic";
    license = licenses.gpl3Plus;
    mainProgram = "tuic-client";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
  };
}
