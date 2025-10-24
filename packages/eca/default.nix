{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  jre,
  writeShellScript,
}:

stdenvNoCC.mkDerivation rec {
  pname = "eca";
  version = "0.72.0";

  src = fetchurl {
    url = "https://github.com/editor-code-assistant/eca/releases/download/${version}/eca.jar";
    hash = "sha256-Dw5oLVcxJLV5Tzc2rSxFJdVLpoTQ2sJ6A2Q2Vq7ou4A=";
  };

  nativeBuildInputs = [
    makeWrapper
  ];

  buildInputs = [
    jre
  ];

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    mkdir -p $out/lib

    # Copy the jar file
    cp $src $out/lib/eca.jar

    # Create a wrapper script
    cat > $out/bin/eca << 'EOF'
    #!/bin/sh
    exec java -jar "$out/lib/eca.jar" "$@"
    EOF

    chmod +x $out/bin/eca

    # Wrap the script to ensure JAVA_HOME is set
    wrapProgram $out/bin/eca \
      --set-default JAVA_HOME "${jre}" \
      --prefix PATH : "${jre}/bin"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Editor Code Assistant (ECA) - AI pair programming capabilities agnostic of editor";
    homepage = "https://github.com/editor-code-assistant/eca";
    license = licenses.mit;
    maintainers = with maintainers; [ jojo ];
    mainProgram = "eca";
    platforms = platforms.unix;
  };
}
