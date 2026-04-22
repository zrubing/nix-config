{
  lib,
  stdenvNoCC,
  vscode-extensions,
}:

stdenvNoCC.mkDerivation rec {
  pname = "java-debug";
  version = vscode-extensions.vscjava.vscode-java-debug.version;

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    extDir=${vscode-extensions.vscjava.vscode-java-debug}/share/vscode/extensions/vscjava.vscode-java-debug
    jar=$(find "$extDir/server" -maxdepth 1 -type f -name 'com.microsoft.java.debug.plugin-*.jar' | head -n 1)

    if [ -z "$jar" ]; then
      echo "java-debug jar not found in $extDir/server" >&2
      exit 1
    fi

    mkdir -p $out/lib
    cp "$jar" $out/lib/java-debug.jar

    runHook postInstall
  '';

  meta = with lib; {
    description = "Java debug server jar extracted from VS Code Java Debug extension";
    homepage = "https://github.com/microsoft/vscode-java-debug";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
