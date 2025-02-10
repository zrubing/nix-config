{ stdenv, pkgs }:
stdenv.mkDerivation {

  name = "emacs-rime";
  pname = "emacs-rime";
  buildInputs = [ pkgs.gcc pkgs.librime pkgs.emacs ];
  src = pkgs.fetchFromGitHub {
    owner = "DogLooksGood";
    repo = "emacs-rime";
    rev = "80f09ed36d9f0ca7ce4e1a3ca1020dc4c80ba335";
    sha256 = "0cgmj0j1kwjxx6077sb3b7hzj1xg6ppynyizs8v0h1x8jbngdrq0";

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
