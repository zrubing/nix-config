{
  gtk3,
  libpulseaudio,
  libxml2,
  gtk-layer-shell,
  glib,
  pango,
  fetchFromGitHub,
  versionCheckHook,
  pkg-config,
  rustPlatform,
  rubyPackages,
  lib,
}:

rustPlatform.buildRustPackage rec {
  pname = "rgbar";
  version = "0.1";

  src =
    (fetchFromGitHub {
      owner = "aeghn";
      repo = "rgbar";
      rev = "f7a48e46f7727e0b1b664b06ea8c3c8fa4f1b5bc";
      fetchSubmodules = true;
      hash = "sha256-KqtElqaK6GhShjprflyTusvhW2Doz7r8waC629gKJIQ=";
    }).overrideAttrs
      {
        GIT_CONFIG_COUNT = 1;
        GIT_CONFIG_KEY_0 = "url.https://github.com/.insteadOf";
        GIT_CONFIG_VALUE_0 = "git@github.com:";
      };

  cargoHash = "sha256-oo1W9PSPqA2wFNP+82yXnJyYTJclGvSPKhbLhR8mOvQ=";

  strictDeps = true;

  nativeBuildInputs = [
    pkg-config
  ];

  buildInputs = [
    rubyPackages.gdk3
    glib
    pango
    gtk-layer-shell
    libxml2
    libpulseaudio
    gtk3
  ];
  buildNoDefaultFeatures = true;

  env = {
  };

  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";
  doInstallCheck = false;
  doCheck = false;

}
