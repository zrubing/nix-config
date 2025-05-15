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
    rev = "54058b9eb466576a7a77c9303963ca88967ec58b";
    sha256 = "sha256-nqvUCI2Lf+WGleSaAGbHAJLa10PHbjwWY19hazWwnsU=";
  };

  mvnHash = "sha256-NO2AqU9q5K998HfJm9q3imlVzs3O1R+MafoK890sIN0=";

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
