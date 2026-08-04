{
  lib,
  stdenvNoCC,
  fetchurl,
  nodejs_24,
  makeBinaryWrapper,
}:
stdenvNoCC.mkDerivation (finalAttrs: rec {
  pname = "chrome-devtools-mcp";
  version = "1.6.0";

  src = fetchurl {
    url = "https://registry.npmjs.org/chrome-devtools-mcp/-/chrome-devtools-mcp-${version}.tgz";
    hash = "sha256-HmMsLZcUtPgrTPq077nOV1CFx1/+XpdyODEprwEsnIQ=";
  };

  # npm 发布包已含编译产物（build/），零依赖，无需构建
  dontBuild = true;
  sourceRoot = "package";

  nativeBuildInputs = [makeBinaryWrapper];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/chrome-devtools-mcp
    cp -r . $out/lib/chrome-devtools-mcp/

    mkdir -p $out/bin
    makeWrapper ${lib.getExe nodejs_24} $out/bin/chrome-devtools-mcp \
      --add-flags $out/lib/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js

    runHook postInstall
  '';

  meta = {
    description = "Chrome DevTools MCP server for AI coding agents";
    homepage = "https://github.com/ChromeDevTools/chrome-devtools-mcp";
    license = lib.licenses.asl20;
    maintainers = with lib.maintainers; [];
    mainProgram = "chrome-devtools-mcp";
  };
})
