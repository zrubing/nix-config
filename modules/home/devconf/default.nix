{ config, ... }:
let
  hm = config.lib;
in
{
  dconf.settings = {
    "org/virt-manager/virt-manager/connections" = {
      autoconnect = [ "qemu:///system" ];
      uris = [ "qemu:///system" ];
    };
  };

  home.activation.setupVirt = hm.dag.entryAfter [ "writeBoundary" ] ''
    virsh net-autostart default
  '';

}
