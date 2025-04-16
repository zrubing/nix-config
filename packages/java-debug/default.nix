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
    rev = "${version}";
    sha256 = "sha256-7h2U0l8OE8VrXymggfQ3XSXacvfBbQKCJmQVSo8J4M0=";
  };

  mvnHash = "sha256-BsAlqMznZIZUiu+biGb+peF03u6bevmiGzAwI1zYIng=";

  nativeBuildInputs = [
    maven
    makeWrapper
  ];

  buildInputs = [
    jre
  ];

  buildPhase = ''
    mvn -DskipTests clean package
  '';

  installPhase = ''
    mkdir -p $out/lib
    ls -alh com.microsoft.java.debug.plugin/target/*
    mv com.microsoft.java.debug.plugin/target/com.microsoft.java.debug.plugin-0.53.1.jar \
    $out/lib/java-debug.jar
  '';
}
