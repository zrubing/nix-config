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

    version = "force_unscaled";
    src = super.fetchFromGitHub {
      owner = "Supreeeme";
      repo = "xwayland-satellite";
      tag = null;
      rev = "555f9492ad8d6d2f47af728eb4570e40339541a3";
      sha256 = "sha256-y8+XayMTJE1O2WtHWgUK2/nvLu09p6fX0hRBA1sySJw=";
    };
    cargoDeps = super.rustPlatform.fetchCargoVendor {
      inherit src;
      hash = "sha256-QsU960aRU+ErU7vwoNyuOf2YmKjEWW3yCnQoikLaYeA=";
    };

    cargoSha256 = "sha256-iuIwRCmFk/Xq8Is+DlVRQNDiR0l1Zte1bUb1xC3yd8A=";
    cargoVendorDir = null;

  });
}
