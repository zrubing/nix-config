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
  # Doom 仍走 Emacs 已废弃的 autoload-generate-file-autoloads（见它自己的 FIXME），
  # 而 Emacs 32 把 loaddefs-generate--make-autoload 改成 3 个必填参数，obsolete
  # shim 没跟着改：每个 ;;;###autoload 都展开失败 → 输出为空 → autoload.el 自己的
  # cl-assert 失败，于是任何 `doom` 命令都死于
  #   bin/doom-env:0:0: error: cl-assertion-failed: ((> (point) output-start))
  # 该补丁改用 loaddefs-generate--parse-file，并让 autodef 路径按 arity 调用新版
  # make-autoload。上游修掉 loaddefs.el 里的 FIXME 后，本段与 patch 文件即可删除。
  doomemacs = pkgs.runCommand "doomemacs-patched" {
    nativeBuildInputs = [ pkgs.patch ];
    dontFixup = true;                 # keep bin/* shebangs (#!/usr/bin/env doomscript)
  } ''
    cp -r ${inputs.doomemacs} $out
    chmod -R u+w $out
    patch -p1 --directory=$out < ${./doom-emacs32-loaddefs.patch}
  '';
  doom-modules = inputs.doom-modules;
  hm = config.lib;

  librime-emacs-dir = "${config.xdg.configHome}/emacs.doom/.local/straight/repos/emacs-rime";
  parinfer-rust-lib-dir = "${config.xdg.dataHome}/emacs.doom/parinfer-rust";
  meow-dir = "${config.xdg.configHome}/emacs.doom/modules/editor/meow";
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
      # Merge v3 external modules into core's modules/ directory.
      ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${doom-modules}/modules/ ${config.xdg.configHome}/emacs.doom/modules/

      mkdir -p ${parinfer-rust-lib-dir}
      ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${pkgs.vimPlugins.parinfer-rust}/lib/libparinfer_rust.* ${parinfer-rust-lib-dir}/parinfer-rust.so
    '';
    home.activation.setupMeow = hm.dag.entryAfter [ "installDoomEmacs" ] ''
      if [ ! -d "${meow-dir}" ]; then
        mkdir -p ${meow-dir}
        ${pkgs.git}/bin/git clone https://github.com/meow-edit/doom-meow ${meow-dir}
      fi
    '';

    home.file."${librime-emacs-dir}/librime-emacs.so".source =
      "${pkgs.${namespace}.emacs-rime}/lib/librime-emacs.so";
    home.file.".emacs-profiles.el".text = ''
      ;; Your custom Emacs initialization code here
      (("default" . ((user-emacs-directory . "${config.xdg.configHome}/emacs.doom"))))
    '';
  };
}
