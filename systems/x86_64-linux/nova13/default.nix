{ config, inputs, lib, pkgs, system, namespace, ... }: {
  snowfallorg.users.jojo = { };

  time.timeZone = "Asia/Shanghai";

  imports = [ ./hardware.nix ];

  system.stateVersion = "24.11";

  users.mutableUsers = true;
  users.users.jojo = {
    isNormalUser = true;
    group = "users";
    extraGroups = [ "wheel" "networkmanager" ];
    initialPassword = "test";
  };

  ${namespace} = {
    user.name = "jojo";
    networking.wifi.enable = true;
    #builder.enable = true;
    desktop = {
      enable = true;
      wayland.enable = true;
    };
    #mounts.mito = true;
  };

  services = {
    mihomo.enable = true;
  };

  home = {

    ${namespace} = {
      terminal = "alacritty";
      emacs.enable = true;
      vcs.user = {
        name = "jojo";
        email = "a@b.com";
      };
    };

    home.packages = with pkgs; [ ];

  };

  networking.networkmanager.enable = true;

}
