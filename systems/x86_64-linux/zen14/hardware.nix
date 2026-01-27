{ pkgs, ... }:
{
  imports = [ ../../../hardware/zen14.nix ];

  # bootloader
  boot.loader.efi.canTouchEfiVariables = true;

  boot.loader.systemd-boot.enable = false;

  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.loader = {
    grub = {
      device = "nodev";
      enable = true;
      efiSupport = true;
      gfxmodeEfi = "640x480";
    };
  };

}
