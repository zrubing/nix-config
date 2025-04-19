{
  lib,
  fetchFromGitHub,
  jre,
  makeWrapper,
  maven,
}:

maven.buildMavenPackage rec {
  pname = "java-debug";
  version = "0.53.1";

  src = fetchFromGitHub {
    owner = "microsoft";
    repo = "${pname}";
    rev = "5c7562ade22977b15f76f46d13c098e82cc58ced";
    sha256 = "sha256-7h2U0l8OE8VrXymggfQ3XSXacvfBbQKCJmQVSo8J4M0=";
  };

  mvnHash = "sha256-/O204NYQij0rMMKkQBUusJrqwh9EkIm9q5CG+yJ7Uog=";

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
    mv com.microsoft.java.debug.plugin/target/com.microsoft.java.debug.plugin-0.53.1.jar \
    $out/lib/java-debug.jar
  '';
}
