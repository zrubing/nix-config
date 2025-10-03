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
    owner = "zrubing";
    repo = "${pname}";
    rev = "be0ff9c12ae8fab85c6bcd0947470623c77cfd7d";
    sha256 = "sha256-1M3OU593dsLJs9Mh9H0r45lDbbpV7294BT4dZWf45K8=";
  };

  mvnHash = "sha256-m2ZXyTA37QoCW7XhR4NXgZT9MtYCD/D2eZ880yWPlcg=";

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
