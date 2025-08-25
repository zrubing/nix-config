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
}:

rustPlatform.buildRustPackage rec {
  pname = "rgbar";
  version = "0.1";

  src = fetchFromGitHub {
    owner = "aeghn";
    repo = "rgbar";
    rev = "f66d9a782780dcbe4e979d2b6891326022f060ca";
    hash = "sha256-cAqVWoRRFuRk/mIzZx9Ny/3e8nV4No0sw5AJ+TlM+oA=";
  };

  cargoHash = "sha256-RU6KbBRqWuCO8zUEF6X/1w4Wu+Jy+ipSfVyFEJWfhPs=";

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
