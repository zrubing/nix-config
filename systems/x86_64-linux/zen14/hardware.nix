{
  imports = [ ../../../hardware/xiaoxinpro13.nix ];

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

}
