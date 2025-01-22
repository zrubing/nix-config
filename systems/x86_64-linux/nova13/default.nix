# { namespace, pkgs, ... }: {
#   imports = [ ./hardware.nix ];

#   system.stateVersion = "24.11";

#   snowfallorg.users.jojo = {};

#   ${namespace} = {
#     user.name = "jojo";
#     host = {
#       pubKey = "jojo@nova13";
#       # ip = {
#       #   local = "192.168.1.23";
#       #   remote = null;
#       #   tailscale = "100.112.159.50";
#       # };
#     };

#     networking.wifi.enable = true;
#     #builder.enable = true;
#     desktop = {
#       enable = true;
#       wayland.enable = true;
#     };
#     #mounts.mito = true;
#   };

#   programs.wireshark.enable = true;
#   virtualisation.waydroid.enable = true;

#   environment.systemPackages = with pkgs; [  ];

#   home = {
#     ${namespace} = {
#       terminal = "alacritty";
#       vcs.user = {
#         name = "jojo";
#         email = "a@b.com";
#       };
#     };

#     home.packages = with pkgs; [ ];

#     programs.senpai.enable = true;
#     services.blueman-applet.enable = false;

#     services.easyeffects.enable = true;
#   };
# }
#
# OptiPlex 7070 SFF
#
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

    # programs.senpai.enable = true;
    # services.blueman-applet.enable = false;

    # services.easyeffects.enable = true;
  };

  networking.networkmanager.enable = true;

}
