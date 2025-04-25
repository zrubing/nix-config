{ ... }:
{
  security.pki.certificateFiles = [
    ../../../certs/ecc-ca.crt
  ];
  imports = [ ../../unix/nix-settings ];
}
