{
  lib,
  fetchFromGitHub,
  jre,
  makeWrapper,
  maven,
}:

maven.buildMavenPackage rec {
  pname = "java-debug";
  version = "0.53.2";

  src = fetchFromGitHub {
    owner = "microsoft";
    repo = "${pname}";
    rev = "a1f68f4265458e9386bf16d107c2383b68690e43";
    sha256 = "sha256-Bd/4pzP6mC4N5yXIAMhnTUifu2bSrWZatp9T+sRfCj8=";
  };

  mvnHash = "sha256-su86q2zWS7UmW2TELl/Xs+Z7Mx1ZS5a+V5E+50hCwuk=";

  nativeBuildInputs = [
    maven
    makeWrapper
  ];

  buildInputs = [
    jre
  ];

  buildPhase = ''
    ./mvnw clean install
  '';

  installPhase = ''
    mkdir -p $out/lib
    mv com.microsoft.java.debug.plugin/target/com.microsoft.java.debug.plugin-0.53.2.jar \
    $out/lib/java-debug.jar
  '';
}
