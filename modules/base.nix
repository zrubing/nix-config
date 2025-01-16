{ inputs, config, pkgs, lib, ... }@args:

{

  nixpkgs.overlays = [ inputs.emacs-overlay.overlay ]
    ++ (import ../overlays args);

}
