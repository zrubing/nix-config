# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{

  imports = [
    #    ../../modules/base.nix
    ../../modules/desktop.nix
    ../../modules/system.nix
    #    ../../modules/i3.nix
    ../../modules/miho.nix

    # Include the results of the hardware scan.
    ./hardware-configuration.nix
  ];

  # bootloader
  boot.loader.efi.canTouchEfiVariables = true;

  boot.loader.systemd-boot.enable = false;

  boot.loader = {
    grub = {
      device = "nodev";
      enable = true;
      efiSupport = true;
      gfxmodeEfi = "640x480";
    };
  };

  # Enable networking
  networking.networkmanager.enable = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11"; # Did you read the comment?

}
