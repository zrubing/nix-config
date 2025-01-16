{ pkgs, config, username, inputs, ... }:
let
  gtkEmacsMPS = pkgs.emacs-git.overrideAttrs (old: {
    name = "emacs-git-mps";

    src = pkgs.fetchFromGitHub {
      owner = "emacs-mirror";
      repo = "emacs";
      rev = "42731228d24c37edb2dc848c3a74d5c932a817ef";
      sha256 = "mLTLxypbnc7UcKzRkN9tNY6/g4v+cMsTSJBUZkU/YeA=";
    };

    buildInputs = old.buildInputs ++ [ pkgs.mps pkgs.gtk3 ];

    configureFlags = [
      "--disable-build-details"
      "--with-modules"
      "--with-x-toolkit=gtk3"
      "--with-cairo"
      "--with-xft"
      "--with-sqlite3=yes"
      "--with-compress-install"
      "--with-toolkit-scroll-bars"
      "--with-native-compilation"
      "--without-imagemagick"
      "--with-mailutils"
      "--with-small-ja-dic"
      "--with-tree-sitter"
      "--with-xinput2"
      "--without-xwidgets" # Needed for it to compile properly for some reason
      "--with-dbus"
      "--with-selinux"
      "--with-mps=yes"
    ];
  });
in {

  services.emacs.package = gtkEmacsMPS;
  services.emacs.enable = true;

  programs.emacs = {
    enable = true;
    package = gtkEmacsMPS;
  };
}
