{
  lib,
  buildNpmPackage,
  fetchzip,
  nodejs_20,
  makeWrapper,
}:

buildNpmPackage rec {
  pname = "prettier-plugin-nginx";
  version = "1.0.3";

  nodejs = nodejs_20;

  nativeBuildInputs = [ makeWrapper ];

  src = fetchzip {
    url = "https://registry.npmjs.org/prettier-plugin-nginx/-/prettier-plugin-nginx-${version}.tgz";
    hash = "sha256-fRnmq4qILuf9lfcbPb3U3pkW5y1zIRKSDIEkaOScOuo=";
  };

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    mv package.json package-lock.json node_modules dist $out/

    # 创建可执行文件包装器
    makeWrapper ${lib.getExe nodejs} $out/bin/prettier-plugin-nginx --add-flags $out/dist/index.js


    runHook postInstall

  '';

  npmDepsHash = "sha256-tE9czVsJEfQxLUPiifZll8sV2aGmfCO/uCAgOCKGU+Y=";

  # 从 package-lock.json 复制，因为 npm 包可能不包含
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  # 这个包不需要构建步骤，但依赖会自动安装
  dontNpmBuild = true;

  meta = {
    description = "Prettier plugin for formatting Nginx configuration files";
    homepage = "https://github.com/jxddk/prettier-plugin-nginx";
    downloadPage = "https://www.npmjs.org/package/prettier-plugin-nginx";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ jojo ];
  };
}
