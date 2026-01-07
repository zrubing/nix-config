{ ... }:
{

  programs.virt-manager.enable = true;

  users.groups.libvirtd.members = [ "jojo" ];
  users.users.jojo.extraGroups = [
    "libvirtd"
    "podman"
  ];

  virtualisation.libvirtd.enable = true;

  virtualisation.spiceUSBRedirection.enable = true;
}
