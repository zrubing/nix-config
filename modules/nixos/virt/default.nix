{ config, lib, namespace, ... }:
let
  cfg = config.${namespace}.virt;
in
{
  options.${namespace}.virt.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable virt-manager and libvirtd (QEMU) stack.";
  };

  config = lib.mkIf cfg.enable {
    programs.virt-manager.enable = true;

    users.groups.libvirtd.members = [ "jojo" ];
    users.users.jojo.extraGroups = [
      "libvirtd"
      "podman"
    ];

    virtualisation.libvirtd.enable = true;

    virtualisation.spiceUSBRedirection.enable = true;
  };
}
