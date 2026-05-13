{ ... }:

final: prev:
let
  version = "2.6.4";
  src = prev.fetchzip {
    url = "https://github.com/EasyTier/EasyTier/releases/download/v${version}/easytier-linux-x86_64-v${version}.zip";
    hash = "sha256-tCXofzlql9VaeEAjlP0p3QH3mc7l907LcXAZKl/HNYM=";
    stripRoot = false;
  };
in
{
  easytier = prev.stdenvNoCC.mkDerivation {
    pname = "easytier";
    inherit version src;

    installPhase = ''
      runHook preInstall

      install -Dm755 easytier-linux-x86_64/easytier-core $out/bin/easytier-core
      install -Dm755 easytier-linux-x86_64/easytier-cli $out/bin/easytier-cli

      runHook postInstall
    '';

    meta = (prev.easytier.meta or { }) // {
      homepage = "https://github.com/EasyTier/EasyTier";
      changelog = "https://github.com/EasyTier/EasyTier/releases/tag/v${version}";
      mainProgram = "easytier-core";
    };
  };
}
