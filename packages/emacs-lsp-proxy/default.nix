{
  lib,
  stdenv,
  fetchurl,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "emacs-lsp-proxy";
  version = "0.5.8";

  src = fetchurl {
    url = "https://registry.npmjs.org/@emacs-lsp-proxy/linux-x64/-/linux-x64-${finalAttrs.version}.tgz";
    hash = "sha256-yX7oNe1H8DSlm6+RKue1GQjxdVEYui4Lk5m7pFCrPVU=";
  };

  installPhase = ''
    mkdir -p $out/bin

    tar -xf $src
    cp package/bin/emacs-lsp-proxy $out/bin/emacs-lsp-proxy

    chmod +x $out/bin/emacs-lsp-proxy
  '';

})
