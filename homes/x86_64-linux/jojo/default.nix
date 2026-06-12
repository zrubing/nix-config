{ lib, config, pkgs, namespace, ... }:
{

  home.stateVersion = "25.11";

  home.packages = [
    pkgs.${namespace}."pv-inspect"
  ];

  programs.k9s = {
    enable = true;
    plugins = {
      pv_inspect = {
        shortCut = "p";
        description = "Inspect PVC with pv_inspect";
        scopes = [ "pvc" ];
        command = "pv_inspect";
        background = false;
        args = [
          "-n"
          "$NAMESPACE"
          "$NAME"
        ];
      };
    };
  };

  internal.javalib.enable = true;

  snowfallorg.user.enable = true;

  internal = {

    ccr-router.enable = true;

    #desktop.kde.enable = true;
    desktop.niri.enable = true;
    emacs = {
      enable = true;
      type = "doom";
    };
    terminal = "ghostty";
    ghostty.enable = true;
    gpg.enable = true;
    password-store.enable = true;
    shell = {
      enable = "bash";
      #provider = "MiniMax";
      provider = "GLM";
    };

    cc-proxy.enable = false;
    sops.enable = true;

    bash.enable = true;

    #fish.provider = "MiniMax";
    #fish.provider = "GLM";
    #fish.provider = "Qwen";

    modules = {
      fcitx5.enable = true;
      fuzzel.enable = true;
      packages.enable = true;
      prettier = {
        enable = true;
        nginxPlugin = true;
      };
      tmux.enable = true;
      # eca.enable = true;
    };

    vcs = {
      user = {
        name = "zrubing";
        email = "rubingem@gmail.com";
      };
    };
  };

}
