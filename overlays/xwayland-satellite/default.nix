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
      rev = "3ba30b149f9eb2bbf42cf4758d2158ca8cceef73";
      sha256 = "sha256-IiLr1alzKFIy5tGGpDlabQbe6LV1c9ABvkH6T5WmyRI=";
    };
    cargoDeps = super.rustPlatform.fetchCargoVendor {
      inherit src;
      hash = "sha256-R3xXyXpHQw/Vh5Y4vFUl7n7jwBEEqwUCIZGAf9+SY1M=";
    };

    cargoSha256 = lib.fakeHash;
    cargoVendorDir = null;

    postInstall = ''
      wrapProgram $out/bin/xwayland-satellite \
        --prefix PATH : "${lib.makeBinPath [ super.pkgs.xwayland ]}"
    '';

  });
}
