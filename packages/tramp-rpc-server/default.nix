{
  lib,
  stdenv,
  fetchurl,
}:

let
  platforms = {
    x86_64-linux = {
      url = "https://github.com/ArthurHeymans/emacs-tramp-rpc/releases/download/v0.3.0/tramp-rpc-server-x86_64-unknown-linux-musl-0.3.0.tar.gz";
      hash = "sha256-q37FCDuypENN26hOVJBIBdZMA+EPJGwfu8QyRNkMzqc=";
    };
    aarch64-linux = {
      url = "https://github.com/ArthurHeymans/emacs-tramp-rpc/releases/download/v0.3.0/tramp-rpc-server-aarch64-unknown-linux-musl-0.3.0.tar.gz";
      hash = "sha256-u+2yYLf1K+5YAy3QaA3tyKVLxUhIihp4bMnQVBdWnQs=";
    };
  };
  platform = platforms.${stdenv.hostPlatform.system} or (throw "Unsupported system: ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "tramp-rpc-server";
  version = "0.3.0";

  src = fetchurl {
    url = platform.url;
    hash = platform.hash;
  };

  sourceRoot = ".";

  installPhase = ''
    install -Dm755 tramp-rpc-server $out/bin/tramp-rpc-server
    # Create versioned symlink for Emacs tramp-rpc compatibility
    ln -s $out/bin/tramp-rpc-server $out/bin/tramp-rpc-server-0.3.0
  '';

  meta = {
    description = "RPC server for TRAMP in Emacs";
    homepage = "https://github.com/ArthurHeymans/emacs-tramp-rpc";
    license = lib.licenses.gpl3Only;
    maintainers = [];
    mainProgram = "tramp-rpc-server";
    platforms = ["x86_64-linux" "aarch64-linux"];
  };
}
