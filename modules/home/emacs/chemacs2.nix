{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  hm = config.lib;
  username = config.snowfallorg.user.name;
in
{
  config = {

    home.activation.setupChemacs2 = hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -d "/home/${username}/.emacs.d" ]; then
        ${pkgs.git}/bin/git clone https://github.com/plexus/chemacs2.git /home/${username}/.emacs.d
      fi
    '';
  };
}
