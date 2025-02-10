# ==============================================
# Based on doomemacs's author's config:
#   https://github.com/hlissner/dotfiles/blob/master/modules/editors/emacs.nix
#
# Emacs Tutorials:
#  1. Official: <https://www.gnu.org/software/emacs/tour/index.html>
#  2. Doom Emacs: <https://github.com/doomemacs/doomemacs/blob/master/docs/index.org>
#
{ config, lib, pkgs, namespace, inputs, system, ... }:
with lib;
let
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  cfg = config.${namespace}.emacs;
  hm = config.lib;
  doomemacs = inputs.doomemacs;
  envExtra = lib.mkAfter ''
    export PATH="${config.xdg.configHome}/emacs/bin:$PATH"
  '';
  shellAliases = {
    e = "emacsclient --create-frame"; # gui
    et = "emacsclient --create-frame --tty"; # terminal
  };
  librime-dir = "${config.xdg.dataHome}/emacs/librime";
  emacs-rime-dir = "${config.xdg.dataHome}/emacs/emacs-rime";
  tdlib-dir = "${config.xdg.dataHome}/tdlib";
  librime-emacs-dir =
    "${config.xdg.configHome}/emacs/.local/straight/repos/emacs-rime";
  rime-data-dir = "${config.xdg.dataHome}/rime-data";
  parinfer-rust-lib-dir = "${config.xdg.dataHome}/emacs/parinfer-rust";
  myEmacsPackagesFor = emacs:
    ((pkgs.emacsPackagesFor emacs).emacsWithPackages (epkgs: [ epkgs.vterm ]));
  # to make this symlink work, we need to git clone this repo to your home directory.
  # configPath = "${config.home.homeDirectory}/nix-config/home/base/tui/editors/emacs/doom";
in {
  options.${namespace}.emacs = { enable = mkEnableOption "Emacs Editor"; };

  config = mkIf cfg.enable (mkMerge [
    {

      home.file."${librime-emacs-dir}/librime-emacs.so".source =
        "${pkgs.${namespace}.emacs-rime}/lib/librime-emacs.so";

      home.packages = with pkgs; [

        # compile vterm
        libtool
        librime
        ## Doom dependencies
        git
        (ripgrep.override { withPCRE2 = true; })
        gnutls # for TLS connectivity

        ## Optional dependencies
        fd # faster projectile indexing
        imagemagick # for image-dired
        fd # faster projectile indexing
        zstd # for undo-fu-session/undo-tree compression

        # go-mode
        # gocode # project archived, use gopls instead

        ## Module dependencies
        # :checkers spell
        # (aspellWithDicts (ds: with ds; [en en-computers en-science]))
        # :tools editorconfig
        editorconfig-core-c # per-project style config
        # :tools lookup & :lang org +roam
        sqlite
        # :lang latex & :lang org (latex previews)
        # texlive.combined.scheme-medium
      ];

      programs.bash.bashrcExtra = envExtra;
      programs.zsh.envExtra = envExtra;
      home.shellAliases = shellAliases;
      programs.nushell.shellAliases = shellAliases;

      # xdg.configFile."doom".source = config.lib.file.mkOutOfStoreSymlink configPath;

      home.activation.installDoomEmacs =
        hm.dag.entryAfter [ "writeBoundary" ] ''
          ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${doomemacs}/ ${config.xdg.configHome}/emacs/

          # librime for emacs-rime
          mkdir -p ${librime-dir}
          ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${pkgs.librime}/ ${librime-dir}/

          # rime data
          mkdir -p ${rime-data-dir}
          ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${pkgs.rime-data}/ ${rime-data-dir}/

          # tdlib dir
          mkdir -p ${tdlib-dir}
          ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744 ${pkgs-unstable.tdlib}/ ${tdlib-dir}/


          # libparinfer_rust for emacs' parinfer-rust-mode
          mkdir -p ${parinfer-rust-lib-dir}
          ${pkgs.rsync}/bin/rsync -avz --chmod=D2755,F744  ${pkgs.vimPlugins.parinfer-rust}/lib/libparinfer_rust.* ${parinfer-rust-lib-dir}/parinfer-rust.so
        '';
    }

    (mkIf pkgs.stdenv.isLinux (let
      # Do not use emacs-nox here, which makes the mouse wheel work abnormally in terminal mode.
      # pgtk (pure gtk) build add native support for wayland.
      # https://www.gnu.org/savannah-checkouts/gnu/emacs/emacs.html#Releases
      # emacsPkg = myEmacsPackagesFor pkgs.emacs29-pgtk;

      # gtkEmacsMPS = pkgs.emacs-git.overrideAttrs (old: {
      #   name = "emacs-git-mps";

      #   src = pkgs.fetchFromGitHub {
      #     owner = "emacs-mirror";
      #     repo = "emacs";
      #     rev = "02ab0508745ba386fa1f8a4713a3992b8e17a505";
      #     sha256 = "ClZFk1QO7ytmy6rG2PenFrcH6qnEyttpCGllO0i5rAg=";
      #   };

      #   buildInputs = old.buildInputs ++ [ pkgs.mps pkgs.gtk3 ];

      #   configureFlags = [
      #     "--disable-build-details"
      #     "--with-modules"
      #     "--with-x-toolkit=lucid"
      #     "--with-cairo"
      #     "--with-xft"
      #     "--with-sqlite3=yes"
      #     "--with-compress-install"
      #     "--with-toolkit-scroll-bars"
      #     "--with-native-compilation"
      #     #"--without-imagemagick"
      #     "--with-mailutils"
      #     "--with-small-ja-dic"
      #     "--with-tree-sitter"
      #     "--with-xinput2"
      #     "--without-xwidgets" # Needed for it to compile properly for some reason
      #     "--with-dbus"
      #     "--with-selinux"
      #     "--with-mps=yes"
      #   ];
      # });

      #emacsPkg = myEmacsPackagesFor gtkEmacsMPS;
      emacsPkg = inputs.emacs-overlay.packages.${system}.emacs-igc;
    in {

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
    }))

    (mkIf pkgs.stdenv.isDarwin (let
      # macport adds some native features based on GNU Emacs 29
      # https://bitbucket.org/mituharu/emacs-mac/src/master/README-mac
      emacsPkg = myEmacsPackagesFor pkgs.emacs29;
    in {
      home.packages = [ emacsPkg ];
      launchd.enable = true;
      launchd.agents.emacs = {
        enable = true;
        config = {
          ProgramArguments = [
            "${pkgs.bash}/bin/bash"
            "-l"
            "-c"
            "${emacsPkg}/bin/emacs --fg-daemon"
          ];
          StandardErrorPath =
            "${config.home.homeDirectory}/Library/Logs/emacs-daemon.stderr.log";
          StandardOutPath =
            "${config.home.homeDirectory}/Library/Logs/emacs-daemon.stdout.log";
          RunAtLoad = true;
          KeepAlive = true;
        };
      };
    }))
  ]);
}
