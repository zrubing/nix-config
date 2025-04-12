{ config, lib, pkgs, namespace, inputs, system, ... }:
with lib;
let
  emacsPkg = inputs.emacs-overlay.packages.${system}.emacs-igc;
in {
  config = mkIf pkgs.stdenv.isLinux {
    home.packages = [ emacsPkg ];
    services.emacs = {
      enable = true;
      package = emacsPkg;
      client = {
        enable = true;
        arguments = [ " --create-frame" ];
      };
      startWithUserSession = "graphical";
    };
  };
}
