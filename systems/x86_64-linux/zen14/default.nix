{
  config,
  inputs,
  lib,
  pkgs,
  system,
  namespace,
  ...
}:
{
  snowfallorg.users.jojo = { };
  snowfallorg.users.hiar = { };

  time.timeZone = "Asia/Shanghai";

  imports = [ ./hardware.nix ];

  system.stateVersion = "25.11";

  users.mutableUsers = true;
  users.users = {

    jojo = {
      uid = 1000;
      isNormalUser = true;
      group = "users";
      extraGroups = [
        "wheel"
        "networkmanager"
        "docker"
        "podman"
      ];
      initialPassword = "test";

      # NOTICE THIS PART
      subUidRanges = [

        {
          startUid = 100000;
          count = 200000;
        }
        {
          startUid = 300000;
          count = 400000;
        }
      ];
      subGidRanges = [

        {
          startGid = 100000;
          count = 200000;
        }
        {
          startGid = 300000;
          count = 400000;
        }
      ];

    };

    hiar = {
      isNormalUser = true;
      group = "users";
      extraGroups = [
        "wheel"
        "networkmanager"
      ];
      initialPassword = "test";
    };
  };

  modules.secrets.desktop.enable = true;

  ${namespace} = {
    user.name = "jojo";
    networking.wifi.enable = true;
    tailscale.headscaleAuthkeyFile = "headscale-authkey-zen14.age";
    #builder.enable = true;
    desktop = {
      #kde.enable = true;
      niri.enable = true;
    };

    #dae.enable = true;
    miho.enable = true;
    ollama.enable = true;
    desktop-programs.enable = true;

    restic.enable = true;
  };

  networking.networkmanager.enable = true;

}
