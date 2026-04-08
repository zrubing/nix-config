{ lib, rustPlatform, fetchFromGitHub }:

rustPlatform.buildRustPackage rec {
  pname = "pv-inspect";
  version = "0.1.4";

  src = fetchFromGitHub {
    owner = "cpg314";
    repo = "pv_inspect";
    rev = "64ba2eb0beee73694e9503cf9b24ad9551989d1b";
    hash = "sha256-QczDarVdVPmOYFFLwDj9la3jT+re9Khpr3C/3oHxK+Q=";
  };

  cargoLock.lockFile = ./Cargo.lock;

  postPatch = ''
    cp ${./Cargo.lock} Cargo.lock
  '';

  meta = with lib; {
    description = "Mount a Kubernetes PersistentVolumeClaim volume on a new pod, shell into it, and mount it via SSHFS";
    homepage = "https://github.com/cpg314/pv_inspect";
    license = with licenses; [ mit asl20 ];
    mainProgram = "pv_inspect";
    platforms = platforms.linux ++ platforms.darwin;
  };
}
