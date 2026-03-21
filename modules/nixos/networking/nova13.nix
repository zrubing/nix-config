{ config, lib, ... }:
{
  config = lib.mkIf (config.networking.hostName == "nova13") {
    networking.extraHosts = lib.mkForce "";
  };
}
