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

  system.stateVersion = "25.05";

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
