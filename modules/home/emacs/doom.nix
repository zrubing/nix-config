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
  doomemacs = inputs.doomemacs;
  hm = config.lib;


  librime-emacs-dir = "${config.xdg.configHome}/emacs.doom/.local/straight/repos/emacs-rime";
  parinfer-rust-lib-dir = "${config.xdg.dataHome}/emacs.doom/parinfer-rust";
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

    home.activation.installDoomEmacs = hm.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${doomemacs}/ ${config.xdg.configHome}/emacs.doom/

      mkdir -p ${parinfer-rust-lib-dir}
      ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${pkgs.vimPlugins.parinfer-rust}/lib/libparinfer_rust.* ${parinfer-rust-lib-dir}/parinfer-rust.so
    '';

    home.file."${librime-emacs-dir}/librime-emacs.so".source =
      "${pkgs.${namespace}.emacs-rime}/lib/librime-emacs.so";
    home.file.".emacs-profiles.el".text = ''
      ;; Your custom Emacs initialization code here
      (("default" . ((user-emacs-directory . "~/${config.xdg.configHome}/.emacs.doom"))))
    '';
  };
}
