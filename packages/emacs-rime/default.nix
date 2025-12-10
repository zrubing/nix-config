{
  stdenv,
  pkgs,
  lib,
}:
stdenv.mkDerivation {

  name = "emacs-rime";
  pname = "emacs-rime";
  buildInputs = [
    pkgs.gcc
    pkgs.librime
    pkgs.emacs
  ];
  src = pkgs.fetchFromGitHub {
    owner = "DogLooksGood";
    repo = "emacs-rime";
    rev = "f927d26e471e7d63de65ffa92897944242f2fd92";
    sha256 = "sha256-/gLue5lCjpC6h3cbYHY92aKE6hdqB2yuSAXnR2VDwLs=";

  };
  # preConfigure = ''
  #   NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -I${pkgs.emacs}/include"
  # '';

  buildPhase = ''
    make lib
  '';

  installPhase = ''
    mkdir -p $out/lib
    cp librime-emacs.so $out/lib/
  '';

}
