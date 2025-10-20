{ config, ... }:
{


  services.easytier = {
    enable = true;

    instances.easytier-net-zen14.configFile = "${config.sops.templates."easytier-config".path}";
  };
}
