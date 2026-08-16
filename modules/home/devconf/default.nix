{
  config,
  lib,
  namespace,
  ...
}:
{
  options.${namespace}.modules.devconf = with lib; {
    enable = mkEnableOption "dev configuration (virt-manager dconf connections)";
  };

  config = lib.mkIf config.${namespace}.modules.devconf.enable {
    dconf.settings = {
      "org/virt-manager/virt-manager/connections" = {
        autoconnect = [ "qemu:///system" ];
        uris = [ "qemu:///system" ];
      };
    };

    home.activation.setupVirt = config.lib.dag.entryAfter [ "writeBoundary" ] ''
      # virsh net-autostart default
    '';
  };
}
