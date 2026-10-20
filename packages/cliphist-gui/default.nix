{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  gtk4,
  gtk4-layer-shell,
  glib,
  makeWrapper,
  imagemagick,
  cliphist,
  wl-clipboard,
  libnotify,
  xdg-utils,
}:

# cliphist 的 GTK4 前端：layer-shell 浮层、行内缩略图、全键盘操作。
# 上游是 workspace（cliphist-gui / launch-gui / snippets / snippetd），这里只构建
# cliphist-gui，避免把 launcher、secret-service 那一串依赖带进来。
rustPlatform.buildRustPackage rec {
  pname = "cliphist-gui";
  version = "0.1.0-unstable-2026-10-10";

  src = fetchFromGitHub {
    owner = "Vib1240n";
    repo = "Cliphist-Gui";
    rev = "6461d2c1a213edb93d5b9a8f5b6917dd7d0a86de";
    hash = "sha256-olH6HXvfWs5jQDy0yTGV8xHSgx26fjMrI4MBOZL1Y8w=";
  };

  cargoHash = "sha256-ztzfxSGhUND/JPZWE9dwFXepl0myoItjrO5mlyNKt5A=";

  nativeBuildInputs = [
    pkg-config
    makeWrapper
  ];

  buildInputs = [
    gtk4
    gtk4-layer-shell
    glib
  ];

  cargoBuildFlags = [
    "-p"
    "cliphist-gui"
  ];

  doCheck = false;

  # 默认 installPhase 会对 workspace 根目录跑 `cargo install --path .`，virtual manifest 不支持。
  installPhase = ''
    runHook preInstall
    install -Dm755 target/*/release/cliphist-gui $out/bin/cliphist-gui
    runHook postInstall
  '';

  # 它自己调用 cliphist / wl-copy / magick / notify-send，PATH 里必须有。
  postFixup = ''
    wrapProgram $out/bin/cliphist-gui \
      --prefix PATH : ${
        lib.makeBinPath [
          cliphist
          wl-clipboard
          imagemagick
          libnotify
          xdg-utils
        ]
      }
  '';

  meta = with lib; {
    description = "GTK4 clipboard manager frontend for cliphist with inline image thumbnails";
    homepage = "https://github.com/Vib1240n/Cliphist-Gui";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "cliphist-gui";
  };
}
