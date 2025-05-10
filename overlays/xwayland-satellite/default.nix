# Snowfall Lib provides access to additional information via a primary argument of
# your overlay.
{
  # Channels are named after NixPkgs instances in your flake inputs. For example,
  # with the input `nixpkgs` there will be a channel available at `channels.nixpkgs`.
  # These channels are system-specific instances of NixPkgs that can be used to quickly
  # pull packages into your overlay.
  channels,

  # Inputs from your flake.
  inputs,
  lib,
  ...
}:
self: super: {
  xwayland-satellite = super.xwayland-satellite.overrideAttrs (old: rec {

    version = "latest";
    src = super.fetchFromGitHub {
      owner = "Supreeeme";
      repo = "xwayland-satellite";
      tag = null;
      rev = "c31679aa41966ee9272bb240703755cb1e7c72e3";
      sha256 = "sha256-5DX9lYmEbkdANCzME2v3coV0EnWOhS7NsTlGBQuqmjM=";
    };
    cargoDeps = super.rustPlatform.fetchCargoVendor {
      inherit src;
      hash = "sha256-QsU960aRU+ErU7vwoNyuOf2YmKjEWW3yCnQoikLaYeA=";
    };

    cargoSha256 = "sha256-iuIwRCmFk/Xq8Is+DlVRQNDiR0l1Zte1bUb1xC3yd8A=";
    cargoVendorDir = null;

    postInstall = ''
      wrapProgram $out/bin/xwayland-satellite \
        --prefix PATH : "${lib.makeBinPath [ super.pkgs.xwayland ]}"
    '';

  });
}
