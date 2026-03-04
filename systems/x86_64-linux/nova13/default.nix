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

  ${namespace} = {
    user.name = "jojo";
    networking.wifi.enable = true;
    tailscale.headscaleAuthkeyFile = "headscale-authkey-nova13.age";
    #builder.enable = true;
    desktop.niri.enable = false;

    home.extraOptions = {
      ${namespace} = {
        desktop.niri.enable = lib.mkForce false;
        emacs.enable = lib.mkForce false;
        devpackages.treeSitter.enable = lib.mkForce false;
        devpackages.vscodeTools.enable = lib.mkForce false;
        devpackages.gui.enable = lib.mkForce false;
        modules.packages.gui.enable = lib.mkForce false;
        modules.packages.emacsTools.enable = lib.mkForce false;
        modules.packages.ocr.enable = lib.mkForce false;
        ghostty.enable = lib.mkForce false;
        modules.fuzzel.enable = lib.mkForce false;
        modules.fcitx5.enable = lib.mkForce false;
      };
    };

    #dae.enable = true;
    miho.enable = true;
    desktop-programs.enable = false;

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
