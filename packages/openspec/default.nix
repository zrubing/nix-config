{
  lib,
  stdenv,
  fetchFromGitHub,
  nodejs_20,
  pnpm_9,
  makeBinaryWrapper,
}:

stdenv.mkDerivation (finalAttrs: rec {
  pname = "openspec";
  version = "0.13.0";

  src = fetchFromGitHub {
    owner = "Fission-AI";
    repo = "OpenSpec";
    rev = "5855fa2353ef75e613dae7bc4ccd71c6cdb428f1";
    hash = "sha256-W/9E3/LMWdR2UQsnnaZ8u42NCmZGT50KxmEGL7R5o1I=";
  };

  nativeBuildInputs = [
    nodejs_20
    pnpm_9.configHook
    makeBinaryWrapper
  ];

  pnpmDeps = pnpm_9.fetchDeps {
    inherit pname version src;

    fetcherVersion = 1;
    hash = "sha256-aEWMZK0qOLaNGyWQ8WCOK3GzV7fzev9eYq8zORkIvoU=";
  };

  buildPhase = ''
    runHook preBuild

    # 用离线模式生成 node_modules
    pnpm run build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{bin,lib/openspec}
    cp -r node_modules bin dist $out/lib/openspec
    cp package.json $out/lib/openspec/

    makeWrapper ${lib.getExe nodejs_20} $out/bin/openspec \
      --inherit-argv0 \
      --add-flags $out/lib/openspec/bin/openspec.js

    runHook postInstall
  '';

  meta = {
    description = "OpenSpec language server";
    homepage = "https://github.com/Fission-AI/OpenSpec";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ ];  # 可以后续添加维护者
    mainProgram = "openspec";
  };
})
