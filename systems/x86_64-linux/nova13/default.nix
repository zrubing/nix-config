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

  system.stateVersion = "24.11";

  users.mutableUsers = true;
  users.users = {

    jojo = {
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
    tailscale.headscaleAuthkeyFile  = "headscale-authkey-nova13.age";
    #builder.enable = true;
    desktop = {
      #kde.enable = true;
      niri.enable = true;
    };

    #dae.enable = true;
    miho.enable = true;
    desktop-programs.enable = true;

    restic.enable = true;
  };

  # home = {

  #   ${namespace} = {
  #     terminal = "alacritty";
  #     emacs.enable = true;
  #     vcs.user = {
  #       name = "jojo";
  #       email = "a@b.com";
  #     };
  #   };

  #   home.packages = with pkgs; [ ];

  # };

  networking.networkmanager.enable = true;

}
