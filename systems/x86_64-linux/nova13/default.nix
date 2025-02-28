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

  ${namespace} = {
    user.name = "jojo";
    networking.wifi.enable = true;
    #builder.enable = true;
    desktop = {
      kde.enable = true;
    };

    dae.enable = true;
    desktop-programs.enable = true;
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
