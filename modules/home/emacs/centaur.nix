{
  config,
  lib,
  pkgs,
  namespace,
  inputs,
  system,
  ...
}:
with lib;
let
  hm = config.lib;
in
{
  config = {
    home.packages = with pkgs; [
      libtool
      librime
      git
      (ripgrep.override { withPCRE2 = true; })
      gnutls
      fd
      imagemagick
      zstd
      editorconfig-core-c
      sqlite
    ];

    home.activation.setupCentaurEmacs = hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -d "${config.xdg.configHome}/emacs.centaur" ]; then
        ${pkgs.git}/bin/git clone https://github.com/seagle0128/.emacs.d ${config.xdg.configHome}/emacs.centaur
      fi
    '';

    home.file.".emacs-profiles.el".text = ''
      ;; Your custom Emacs initialization code here
      (("default" . ((user-emacs-directory . "${config.xdg.configHome}/emacs.centaur"))))
    '';
  };
}
