{
  lib,
  pkgs,
  namespace,
  ...
}:
{

  systemd.services.corplink = {
    after = [ "network.target" ];

    serviceConfig = {
      ExecStart = "${pkgs.${namespace}.feilian}/apps/com.volcengine.feilian/files/corplink-service";
      #ExecStopPost = "/bin/rm -f /etc/NetworkManager/conf.d/corplink-nm.conf";
      Type = "simple";
    };

    wantedBy = [ "multi-user.target" ];
  };
}
